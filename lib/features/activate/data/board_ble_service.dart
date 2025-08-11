// lib/features/activation/data/board_ble_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

class BoardBleService {
  final FlutterReactiveBle _ble;
  StreamSubscription<ConnectionStateUpdate>? _connSub;

  final Map<String, List<DiscoveredService>> _servicesCache = {};
  final Map<String, _WriteEndpoint> _writeEndpoint = {};
  final Map<String, int> _mtuCache = {};

  BoardBleService(this._ble);

  Future<void> dispose() async {
    await _connSub?.cancel();
    _connSub = null;
  }

  /// Connect → brief delay → discover → pick writable → request MTU.
  Future<void> connect(String deviceId) async {
    await _connSub?.cancel();

    final completer = Completer<void>();
    _connSub = _ble
        .connectToDevice(
          id: deviceId,
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen((update) async {
      if (update.connectionState == DeviceConnectionState.connected &&
          !completer.isCompleted) {
        try {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final services = await _ble.discoverServices(deviceId);
          _servicesCache[deviceId] = services;

          _writeEndpoint[deviceId] = _pickWritableEndpoint(deviceId, services);

          try {
            final mtu = await _ble.requestMtu(deviceId: deviceId, mtu: 247);
            _mtuCache[deviceId] = mtu;
          } catch (_) {
            // iOS ignores; some stacks may fail → fine
          }

          if (kDebugMode) {
            debugPrint(await gattTable(deviceId));
            debugChosenEndpoint(deviceId);
          }

          completer.complete();
        } catch (e) {
          completer.completeError(e);
        }
      }
      if (update.failure != null && !completer.isCompleted) {
        completer.completeError(update.failure!);
      }
    }, onError: (e, _) {
      if (!completer.isCompleted) completer.completeError(e);
    });

    return completer.future;
  }

  Future<void> disconnect() async {
    await _connSub?.cancel();
    _connSub = null;
  }

  // ================== PUBLIC: multi-frame "i|<json-part>|" ... "N|<json-part>|end" ==================

  Future<void> sendConfig({
    required String deviceId,
    required Map<String, dynamic> payload,
    int sections = 16,                 // firmware expects 16 frames
    int interFrameDelayMs = 900,       // pacing between frames
    bool preferNoResponse = false,     // force writeWithoutResponse if desired
  }) async {
    // Ensure endpoint exists
    var ep = await _ensureWriteEndpoint(deviceId);

    // Optionally force write mode (some firmwares only accept WNR)
    if (preferNoResponse && ep.writeWithoutResponse) {
      overrideWriteCharacteristic(
        deviceId: deviceId,
        serviceId: ep.qc.serviceId,
        characteristicId: ep.qc.characteristicId,
        writeWithResponse: false,
        writeWithoutResponse: true,
      );
      ep = await _ensureWriteEndpoint(deviceId);
    }

    // JSON → bytes
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final total = bytes.length;

    // Max write size per GATT write (ATT header ~3 bytes)
    final mtu = _mtuCache[deviceId];
    final maxWrite =
        Platform.isIOS ? 20 : ((mtu != null && mtu > 3) ? (mtu - 3) : 20);

    // Preflight capacity across frames (accounts for "i|" and tail "|"/"|end")
    final capacity = _exactCapacity(sections, maxWrite);
    if (capacity < total) {
      throw Exception(
        'Payload ${total}B > capacity ${capacity}B '
        '(${sections} frames @ maxWrite=$maxWrite). '
        'Increase MTU or sections, or shrink payload.',
      );
    }

    int offset = 0;
    for (int i = 1; i <= sections; i++) {
      final isLast = (i == sections);

      final headerStr = '$i|';
      final tailStr = isLast ? '|end' : '|'; // last frame ends with "|end"
      final headerLen = utf8.encode(headerStr).length;
      final tailLen = utf8.encode(tailStr).length;

      final availForData = maxWrite - headerLen - tailLen;
      if (availForData <= 0) {
        throw Exception(
          'MTU too small for headers at frame $i (maxWrite=$maxWrite).',
        );
      }

      final remaining = total - offset;
      final take = remaining > 0 ? math.min(availForData, remaining) : 0;

      final bb = BytesBuilder();
      bb.add(utf8.encode(headerStr));
      if (take > 0) {
        bb.add(bytes.sublist(offset, offset + take));
        offset += take;
      }
      bb.add(utf8.encode(tailStr));
      final frameBytes = bb.toBytes();

      // Single attempt — no retry:
      await _writeWithFallback(ep, frameBytes);

      if (!isLast && interFrameDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: interFrameDelayMs));
      }
    }

    if (offset < total) {
      throw Exception(
        'Internal sizing error: only sent $offset of $total bytes.',
      );
    }
  }

  // ================== Internals & helpers ==================

  int _exactCapacity(int sections, int maxWrite) {
    int cap = 0;
    for (int i = 1; i <= sections; i++) {
      final headerLen = utf8.encode('$i|').length;
      final tailLen =
          (i == sections) ? utf8.encode('|end').length : utf8.encode('|').length;
      final avail = maxWrite - headerLen - tailLen;
      cap += (avail > 0) ? avail : 0;
    }
    return cap;
  }

  Future<_WriteEndpoint> _ensureWriteEndpoint(String deviceId) async {
    final cached = _writeEndpoint[deviceId];
    if (cached != null) return cached;

    final services =
        _servicesCache[deviceId] ?? await _ble.discoverServices(deviceId);
    final picked = _pickWritableEndpoint(deviceId, services);
    _writeEndpoint[deviceId] = picked;
    return picked;
  }

  // Dynamic: choose best writable char from discovered GATT (no hard-coded UUIDs)
  _WriteEndpoint _pickWritableEndpoint(
    String deviceId,
    List<DiscoveredService> services,
  ) {
    _Candidate? best;

    for (final s in services) {
      final hasNotifyMate = s.characteristics.any(
        (x) => x.isNotifiable || x.isIndicatable,
      );

      for (final c in s.characteristics) {
        final wnr = c.isWritableWithoutResponse;
        final wwr = c.isWritableWithResponse;
        if (!wnr && !wwr) continue;

        int score = 0;
        if (wnr) score += 3; // prefer faster WNR
        if (wwr) score += 2; // compatible WWR
        if (hasNotifyMate) score += 1; // UART-like hint

        final cand = _Candidate(
          serviceId: s.serviceId,
          charId: c.characteristicId,
          writeWithResponse: wwr,
          writeWithoutResponse: wnr,
          score: score,
        );

        if (best == null || cand.score > best!.score) {
          best = cand;
        }
      }
    }

    if (best == null) {
      throw Exception(
        'No writable characteristic found. Verify with a BLE explorer app.',
      );
    }

    return _WriteEndpoint(
      qc: QualifiedCharacteristic(
        deviceId: deviceId,
        serviceId: best!.serviceId,
        characteristicId: best!.charId,
      ),
      writeWithResponse: best!.writeWithResponse,
      writeWithoutResponse: best!.writeWithoutResponse,
    );
  }

  // Optional: list all writable candidates (handy for debugging / UI picker)
  List<Map<String, dynamic>> gattWriteCandidates(String deviceId) {
    final services = _servicesCache[deviceId] ?? const <DiscoveredService>[];
    final out = <Map<String, dynamic>>[];

    for (final s in services) {
      final hasNotifyMate = s.characteristics.any(
        (x) => x.isNotifiable || x.isIndicatable,
      );
      for (final c in s.characteristics) {
        if (c.isWritableWithResponse || c.isWritableWithoutResponse) {
          int score = 0;
          if (c.isWritableWithoutResponse) score += 3;
          if (c.isWritableWithResponse) score += 2;
          if (hasNotifyMate) score += 1;

          out.add({
            'service': s.serviceId.toString(),
            'characteristic': c.characteristicId.toString(),
            'writeWithResponse': c.isWritableWithResponse,
            'writeWithoutResponse': c.isWritableWithoutResponse,
            'notify': c.isNotifiable,
            'indicate': c.isIndicatable,
            'score': score,
          });
        }
      }
    }
    out.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
    return out;
  }

  Future<void> _writeWithFallback(_WriteEndpoint ep, List<int> value) async {
    final both = ep.writeWithResponse && ep.writeWithoutResponse;

    Future<void> wRsp() =>
        _ble.writeCharacteristicWithResponse(ep.qc, value: value);
    Future<void> wNoRsp() =>
        _ble.writeCharacteristicWithoutResponse(ep.qc, value: value);

    try {
      if (both) {
        await wRsp();
        return;
      }
      if (ep.writeWithResponse) {
        await wRsp();
        return;
      }
      if (ep.writeWithoutResponse) {
        await wNoRsp();
        return;
      }
      throw Exception('Resolved characteristic is not writable.');
    } catch (e) {
      debugPrint(
        'BLE write failed on ${ep.qc.serviceId}/${ep.qc.characteristicId}: $e',
      );
      rethrow; // no retries
    }
  }

  // --------- optional debug helpers ---------

  Future<String> gattTable(String deviceId) async {
    final services =
        _servicesCache[deviceId] ?? await _ble.discoverServices(deviceId);
    final buf = StringBuffer();
    for (final s in services) {
      buf.writeln('Service: ${s.serviceId.toString().toLowerCase()}');
      for (final c in s.characteristics) {
        buf.writeln(
          '  Char: ${c.characteristicId.toString().toLowerCase()} '
          '[read:${c.isReadable} write:${c.isWritableWithResponse} '
          'wnr:${c.isWritableWithoutResponse} notify:${c.isNotifiable} '
          'indicate:${c.isIndicatable}]',
        );
      }
    }
    return buf.toString();
  }

  void debugChosenEndpoint(String deviceId) {
    final ep = _writeEndpoint[deviceId];
    if (ep == null) {
      debugPrint('No endpoint chosen yet.');
      return;
    }
    debugPrint(
      'Write endpoint:\n'
      '  Service: ${ep.qc.serviceId}\n'
      '  Char   : ${ep.qc.characteristicId}\n'
      '  Props  : write=${ep.writeWithResponse} wnr=${ep.writeWithoutResponse}',
    );
  }

  void overrideWriteCharacteristic({
    required String deviceId,
    required Uuid serviceId,
    required Uuid characteristicId,
    bool writeWithResponse = true,
    bool writeWithoutResponse = false,
  }) {
    _writeEndpoint[deviceId] = _WriteEndpoint(
      qc: QualifiedCharacteristic(
        deviceId: deviceId,
        serviceId: serviceId,
        characteristicId: characteristicId,
      ),
      writeWithResponse: writeWithResponse,
      writeWithoutResponse: writeWithoutResponse,
    );
  }
}

class _WriteEndpoint {
  final QualifiedCharacteristic qc;
  final bool writeWithResponse;
  final bool writeWithoutResponse;
  _WriteEndpoint({
    required this.qc,
    required this.writeWithResponse,
    required this.writeWithoutResponse,
  });
}

class _Candidate {
  final Uuid serviceId;
  final Uuid charId;
  final bool writeWithResponse;
  final bool writeWithoutResponse;
  final int score;
  _Candidate({
    required this.serviceId,
    required this.charId,
    required this.writeWithResponse,
    required this.writeWithoutResponse,
    required this.score,
  });
}
