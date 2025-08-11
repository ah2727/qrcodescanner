// lib/features/activation/data/board_ble_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
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

  /// Connect -> small delay -> discover -> pick writable -> request MTU.
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

          if (kDebugMode) debugPrint(await gattTable(deviceId));

          _writeEndpoint[deviceId] = _pickWritableEndpoint(deviceId, services);

          try {
            // iOS ignores; Android may negotiate 185/247/517.
            final mtu = await _ble.requestMtu(deviceId: deviceId, mtu: 247);
            _mtuCache[deviceId] = mtu;
          } catch (_) {/* ignore */}
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

  // ---------------- Debug helpers ----------------

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

  Future<void> testWriteSmall(String deviceId) async {
    final ep = await _ensureWriteEndpoint(deviceId);
    debugChosenEndpoint(deviceId);
    await _writeWithFallback(ep, const [0x50, 0x49, 0x4E, 0x47]); // "PING"
  }

  // Allow manual override if you add a picker UI.
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

  // ---------------- Public API ----------------

  /// Sends ONLY raw data as string frames:
  ///   "1|<chunk>" ... "N|<chunk>|END"
  /// Exactly [sections] frames. One BLE write per frame. No inner chunking.
  Future<void> sendConfig({
    required String deviceId,
    required Map<String, dynamic> payload,
    int sections = 16,
    int interFrameDelayMs = 800,     // safer default pacing
    bool preferNoResponse = false,   // force writeWithoutResponse if needed
  }) async {
    final ep = await _ensureWriteEndpoint(deviceId);

    // Optional: force write mode (some firmwares only accept NoResponse).
    if (preferNoResponse && ep.writeWithoutResponse) {
      overrideWriteCharacteristic(
        deviceId: deviceId,
        serviceId: ep.qc.serviceId,
        characteristicId: ep.qc.characteristicId,
        writeWithResponse: false,
        writeWithoutResponse: true,
      );
    }

    final data = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final total = data.length;

    final mtu = _mtuCache[deviceId];
    final maxPacket = Platform.isIOS
        ? 20
        : ((mtu != null && mtu > 3) ? (mtu - 3) : 20);

    // Preflight: exact capacity across N frames (accounts for header + |END).
    final capacity = _exactCapacity(sections, maxPacket);
    if (capacity < total) {
      throw Exception(
        'Payload ${total}B > capacity ${capacity}B '
        '(${sections} frames @ MTU→maxWrite=$maxPacket). '
        'Increase MTU or sections, or shrink payload.',
      );
    }

    // Send frames
    int offset = 0;
    for (int i = 1; i <= sections; i++) {
      final isLast = i == sections;
      final header = '$i|';
      final headerLen = utf8.encode(header).length;
      final endLen = isLast ? 4 : 0; // "|END"
      final avail = maxPacket - headerLen - endLen;
      final take = (total - offset) > 0
          ? (((total - offset) <= avail) ? (total - offset) : avail)
          : 0;

      final bb = BytesBuilder();
      bb.add(utf8.encode(header));
      if (take > 0) {
        bb.add(data.sublist(offset, offset + take));
        offset += take;
      }
      if (isLast) {
        bb.add(utf8.encode('|END'));
      }

      final frameBytes = bb.toBytes();

      // Single write with mode fallback; on transient GATT, reconnect+retry once.
      try {
        await _writeWithFallback(_writeEndpoint[deviceId]!, frameBytes);
      } catch (e) {
        if (_looksTransientGatt(e)) {
          // reconnect once and retry this frame
          await _retryOnce(deviceId);
          await _writeWithFallback(_writeEndpoint[deviceId]!, frameBytes);
        } else {
          debugPrint(
            'Write failed on frame $i (len=${frameBytes.length}, max=$maxPacket): $e',
          );
          rethrow;
        }
      }

      if (!isLast && interFrameDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: interFrameDelayMs));
      }
    }

    // Must have consumed all payload
    if (offset < total) {
      throw Exception(
        'Internal sizing error: not all bytes sent (sent $offset / $total).',
      );
    }
  }

  // ---------------- Internals ----------------

  int _exactCapacity(int sections, int maxPacket) {
    int cap = 0;
    for (int i = 1; i <= sections; i++) {
      final headerLen = utf8.encode('$i|').length;
      final endLen = (i == sections) ? 4 : 0; // "|END"
      final avail = maxPacket - headerLen - endLen;
      cap += (avail > 0) ? avail : 0;
    }
    return cap;
  }

  Future<void> _retryOnce(String deviceId) async {
    await disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await connect(deviceId);
  }

  bool _looksTransientGatt(Object e) {
    final m = e.toString().toLowerCase();
    return m.contains('133') || m.contains('gatt') || m.contains('timeout');
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

  _WriteEndpoint _pickWritableEndpoint(
      String deviceId, List<DiscoveredService> services) {
    DiscoveredService? svc;
    DiscoveredCharacteristic? ch;

    // Prefer write-with-response first (more compatible),
    // then fall back to write-without-response if not present.
    for (final s in services) {
      for (final c in s.characteristics) {
        if (c.isWritableWithResponse) { svc = s; ch = c; break; }
      }
      if (ch != null) break;
    }
    if (ch == null) {
      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.isWritableWithoutResponse) { svc = s; ch = c; break; }
        }
        if (ch != null) break;
      }
    }

    if (svc == null || ch == null) {
      throw Exception('No writable characteristic found. Verify with nRF Connect.');
    }

    return _WriteEndpoint(
      qc: QualifiedCharacteristic(
        deviceId: deviceId,
        serviceId: svc.serviceId,
        characteristicId: ch.characteristicId,
      ),
      writeWithResponse: ch.isWritableWithResponse,
      writeWithoutResponse: ch.isWritableWithoutResponse,
    );
  }

  /// One BLE write with mode fallback (with-response -> without-response if both).
  Future<void> _writeWithFallback(_WriteEndpoint ep, List<int> value) async {
    final both = ep.writeWithResponse && ep.writeWithoutResponse;

    Future<void> wRsp() =>
        _ble.writeCharacteristicWithResponse(ep.qc, value: value);
    Future<void> wNoRsp() =>
        _ble.writeCharacteristicWithoutResponse(ep.qc, value: value);

    try {
      if (both) { await wRsp(); return; }
      if (ep.writeWithResponse) { await wRsp(); return; }
      if (ep.writeWithoutResponse) { await wNoRsp(); return; }
      throw Exception('Resolved characteristic is not writable.');
    } catch (e) {
      if (both) {
        try { await wNoRsp(); return; } catch (_) {}
      }
      debugPrint('BLE write failed on ${ep.qc.serviceId}/${ep.qc.characteristicId}: $e');
      rethrow;
    }
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
