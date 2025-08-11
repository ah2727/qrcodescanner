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
  final Map<String, _RxEndpoint> _rxEndpoint = {};
  final Map<String, int> _mtuCache = {};

  // RX state
  final Map<String, StreamSubscription<List<int>>> _rxSubs = {};
  final Map<String, StreamController<List<int>>> _rxBytesCtrls = {};
  final Map<String, StreamController<String>> _rxTextCtrls = {};
  final Map<String, StringBuffer> _rxBuffers = {};
  int? _minSectionsFor({
    required int total,
    required int maxPacket,
    int maxSections = 6400,
  }) {
    for (int n = 1; n <= maxSections; n++) {
      if (_exactCapacity(n, maxPacket) >= total) return n;
    }
    return null; // not enough even at maxSections
  }

  BoardBleService(this._ble);

  Future<void> dispose() async {
    for (final s in _rxSubs.values) {
      await s.cancel();
    }
    for (final c in _rxBytesCtrls.values) {
      await c.close();
    }
    for (final c in _rxTextCtrls.values) {
      await c.close();
    }
    await _connSub?.cancel();
    _connSub = null;
  }

  /// Connect → brief delay → discover → pick writable → pick RX → request MTU.
  Future<void> connect(String deviceId) async {
    await _connSub?.cancel();

    final completer = Completer<void>();
    _connSub = _ble
        .connectToDevice(
          id: deviceId,
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen(
          (update) async {
            if (update.connectionState == DeviceConnectionState.connected &&
                !completer.isCompleted) {
              try {
                await Future<void>.delayed(const Duration(milliseconds: 300));
                final services = await _ble.discoverServices(deviceId);
                _servicesCache[deviceId] = services;

                // pick TX (write)
                _writeEndpoint[deviceId] = _pickWritableEndpoint(
                  deviceId,
                  services,
                );
                // pick RX (notify/indicate), prefer same service as TX
                _rxEndpoint[deviceId] = _pickRxEndpoint(
                  deviceId,
                  services,
                  _writeEndpoint[deviceId]!.qc.serviceId,
                );

                // negotiate MTU (Android)
                try {
                  final mtu = await _ble.requestMtu(
                    deviceId: deviceId,
                    mtu: 247,
                  );
                  _mtuCache[deviceId] = mtu;
                } catch (_) {
                  /* ignore */
                }

                if (kDebugMode) {
                  debugPrint(await gattTable(deviceId));
                  debugChosenEndpoint(deviceId);
                  debugChosenRx(deviceId);
                }

                // auto-start RX streams (lazy-start also available via getters)
                _ensureRxStreams(deviceId);

                completer.complete();
              } catch (e) {
                completer.completeError(e);
              }
            }
            if (update.failure != null && !completer.isCompleted) {
              completer.completeError(update.failure!);
            }
          },
          onError: (e, _) {
            if (!completer.isCompleted) completer.completeError(e);
          },
        );

    return completer.future;
  }

  Future<void> disconnect() async {
    await _rxSubs[ /*id?*/ '']?.cancel(); // no-op if null
    for (final s in _rxSubs.values) {
      await s.cancel();
    }
    _rxSubs.clear();
    await _connSub?.cancel();
    _connSub = null;
  }
  // Replace ONLY this method in BoardBleService

  // Replace ONLY this method in BoardBleService

  Future<void> sendConfig({
    required String deviceId,
    required Map<String, dynamic> payload,
    int? sections, // if null/<=0 → auto; if set → will be adjusted
    int interFrameDelayMs = 800, // pacing between frames
    bool preferNoResponse = false, // force writeWithoutResponse if needed
    int maxSections = 64, // hard cap for auto-expand
  }) async {
    // resolve endpoint
    var ep = await _ensureWriteEndpoint(deviceId);

    // optionally force WNR
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

    // we hard-cap each frame to 20B (includes header and, on last frame, "|END")
    const int maxPacket = 20;

    // decide section count dynamically
    final needed = _minSectionsFor(
      total: total,
      maxPacket: maxPacket,
      maxSections: maxSections,
    );
    if (needed == null) {
      throw Exception(
        'Payload ${total}B exceeds capacity of $maxSections sections '
        '(${_exactCapacity(maxSections, maxPacket)}B @ 20B/frame). '
        'Increase maxSections or shrink payload.',
      );
    }

    // if caller passed sections, we’ll adjust (shrink/expand) to the minimum required
    final frames = (sections == null || sections <= 0) ? needed : needed;

    if (kDebugMode) {
      debugPrint(
        'sendConfig: total=${total}B, using $frames frame(s) @ ≤$maxPacket bytes each',
      );
    }

    // send frames
    int offset = 0;
    for (int i = 1; i <= frames; i++) {
      final isLast = i == frames;

      final header = '$i|';
      final headerLen = utf8.encode(header).length;
      final endLen = isLast ? 4 : 0; // "|END"
      final avail = maxPacket - headerLen - endLen;
      if (avail <= 0) {
        throw Exception('Frame $i has no room for data (max=$maxPacket).');
      }

      final remain = total - offset;
      final take = remain > 0 ? (remain <= avail ? remain : avail) : 0;

      final bb = BytesBuilder();
      bb.add(utf8.encode(header));
      if (take > 0) {
        bb.add(bytes.sublist(offset, offset + take));
        offset += take;
      }
      if (isLast) {
        bb.add(utf8.encode('|END'));
      }

      final frame = bb.toBytes();
      if (frame.length > maxPacket) {
        throw Exception('Frame $i is ${frame.length}B, exceeds ${maxPacket}B.');
      }
      if (kDebugMode) {
        debugPrint('frame $i/$frames -> ${frame.length}B');
      }

      await _writeWithFallback(ep, frame);

      if (!isLast && interFrameDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: interFrameDelayMs));
      }
    }

    if (offset < total) {
      throw Exception('Internal sizing error: sent $offset of $total bytes.');
    }
  }

  // ================== RX: subscribe & expose streams ==================

  /// Raw bytes stream from the RX characteristic (broadcast).
  Stream<List<int>> rxBytesStream(String deviceId) =>
      _ensureRxStreams(deviceId).bytes.stream;

  /// UTF-8 decoded text stream (broadcast). By default, emits as chunks arrive.
  /// If you want line-based messages, pass a delimiter to split (e.g., '\n' or '|end').
  Stream<String> rxTextStream(String deviceId, {String? splitOn}) {
    final holder = _ensureRxStreams(deviceId);
    if (splitOn == null) return holder.text.stream;

    // Build a derived stream that splits on delimiter.
    final delim = splitOn;
    final ctrl = StreamController<String>.broadcast();
    String buffer = '';

    final sub = holder.text.stream.listen(
      (chunk) {
        buffer += chunk;
        int idx;
        while ((idx = buffer.indexOf(delim)) != -1) {
          final part = buffer.substring(0, idx);
          ctrl.add(part);
          buffer = buffer.substring(idx + delim.length);
        }
      },
      onError: ctrl.addError,
      onDone: ctrl.close,
      cancelOnError: false,
    );

    ctrl.onCancel = () => sub.cancel();
    return ctrl.stream;
  }

  _RxStreamsHolder _ensureRxStreams(String deviceId) {
    // create controllers if missing
    final bytesCtrl = _rxBytesCtrls.putIfAbsent(
      deviceId,
      () => StreamController<List<int>>.broadcast(),
    );
    final textCtrl = _rxTextCtrls.putIfAbsent(
      deviceId,
      () => StreamController<String>.broadcast(),
    );
    _rxBuffers.putIfAbsent(deviceId, () => StringBuffer());

    // subscribe if not already
    if (_rxSubs[deviceId] == null) {
      final ep = _rxEndpoint[deviceId];
      if (ep == null) {
        // try pick now (in case connect() caller didn't wait)
        final services = _servicesCache[deviceId];
        if (services != null) {
          _rxEndpoint[deviceId] = _pickRxEndpoint(
            deviceId,
            services,
            _writeEndpoint[deviceId]?.qc.serviceId,
          );
        }
      }
      final rx = _rxEndpoint[deviceId];
      if (rx != null) {
        _rxSubs[deviceId] = _ble
            .subscribeToCharacteristic(rx.qc)
            .listen(
              (data) {
                // bytes
                if (!bytesCtrl.isClosed) bytesCtrl.add(data);
                // text
                final asText = _safeDecodeUtf8(data);
                if (!textCtrl.isClosed && asText.isNotEmpty)
                  textCtrl.add(asText);
              },
              onError: (e) {
                if (!bytesCtrl.isClosed) bytesCtrl.addError(e);
                if (!textCtrl.isClosed) textCtrl.addError(e);
              },
            );
      }
    }
    return _RxStreamsHolder(bytes: bytesCtrl, text: textCtrl);
  }

  String _safeDecodeUtf8(List<int> data) {
    try {
      return utf8.decode(data, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(data);
    }
  }

  // ================== Internals & helpers ==================

  int _exactCapacity(int sections, int maxWrite) {
    int cap = 0;
    for (int i = 1; i <= sections; i++) {
      final headerLen = utf8.encode('$i|').length;
      final tailLen = (i == sections)
          ? utf8.encode('|end').length
          : utf8.encode('|').length;
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

  // ---------- dynamic pickers (no hard-coded UUIDs) ----------

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
          notifyMate: hasNotifyMate,
          score: score,
        );

        if (best == null || cand.score > best!.score) best = cand;
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

  _RxEndpoint _pickRxEndpoint(
    String deviceId,
    List<DiscoveredService> services,
    Uuid? preferService,
  ) {
    // 1) prefer notify/indicate in the same service as TX
    if (preferService != null) {
      for (final s in services) {
        if (s.serviceId != preferService) continue;
        for (final c in s.characteristics) {
          if (c.isNotifiable || c.isIndicatable) {
            return _RxEndpoint(
              qc: QualifiedCharacteristic(
                deviceId: deviceId,
                serviceId: s.serviceId,
                characteristicId: c.characteristicId,
              ),
              notify: c.isNotifiable,
              indicate: c.isIndicatable,
            );
          }
        }
      }
    }
    // 2) otherwise, any notify/indicate in any service
    for (final s in services) {
      for (final c in s.characteristics) {
        if (c.isNotifiable || c.isIndicatable) {
          return _RxEndpoint(
            qc: QualifiedCharacteristic(
              deviceId: deviceId,
              serviceId: s.serviceId,
              characteristicId: c.characteristicId,
            ),
            notify: c.isNotifiable,
            indicate: c.isIndicatable,
          );
        }
      }
    }
    throw Exception('No notifiable/indicatable characteristic found for RX.');
  }

  // ---------- write (single attempt, no retry), prefer WNR ----------
  Future<void> _writeOncePreferNoRsp(_WriteEndpoint ep, List<int> value) async {
    Future<void> wNoRsp() =>
        _ble.writeCharacteristicWithoutResponse(ep.qc, value: value);
    Future<void> wRsp() =>
        _ble.writeCharacteristicWithResponse(ep.qc, value: value);

    try {
      if (ep.writeWithoutResponse) {
        await wNoRsp();
        return;
      }
      if (ep.writeWithResponse) {
        await wRsp();
        return;
      }
      throw Exception('Resolved characteristic is not writable.');
    } catch (e) {
      // if char supports both, try the other mode once
      if (ep.writeWithResponse && ep.writeWithoutResponse) {
        try {
          await wRsp();
          return;
        } catch (_) {}
      }
      debugPrint(
        'BLE write failed on ${ep.qc.serviceId}/${ep.qc.characteristicId}: $e',
      );
      rethrow;
    }
  }

  // --------- debug helpers ---------

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
      debugPrint('No TX endpoint chosen yet.');
      return;
    }
    debugPrint(
      'TX endpoint:\n'
      '  Service: ${ep.qc.serviceId}\n'
      '  Char   : ${ep.qc.characteristicId}\n'
      '  Props  : write=${ep.writeWithResponse} wnr=${ep.writeWithoutResponse}',
    );
  }

  void debugChosenRx(String deviceId) {
    final ep = _rxEndpoint[deviceId];
    if (ep == null) {
      debugPrint('No RX endpoint chosen yet.');
      return;
    }
    debugPrint(
      'RX endpoint:\n'
      '  Service: ${ep.qc.serviceId}\n'
      '  Char   : ${ep.qc.characteristicId}\n'
      '  Props  : notify=${ep.notify} indicate=${ep.indicate}',
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

  Future<void> _writeWithFallback(_WriteEndpoint ep, List<int> value) async {
    // Prefer Write-Without-Response first (many UART-style firmwares expect this).
    Future<void> wNoRsp() =>
        _ble.writeCharacteristicWithoutResponse(ep.qc, value: value);
    Future<void> wRsp() =>
        _ble.writeCharacteristicWithResponse(ep.qc, value: value);

    try {
      if (ep.writeWithoutResponse) {
        await wNoRsp();
        return;
      }
      if (ep.writeWithResponse) {
        await wRsp();
        return;
      }
      throw Exception('Resolved characteristic is not writable.');
    } catch (e) {
      // If the characteristic supports both modes, try the other once.
      if (ep.writeWithResponse && ep.writeWithoutResponse) {
        try {
          await wRsp();
          return;
        } catch (_) {
          // fall through to rethrow below
        }
      }
      if (kDebugMode) {
        debugPrint(
          'BLE write failed on ${ep.qc.serviceId}/${ep.qc.characteristicId} '
          '(${value.length}B): $e',
        );
      }
      rethrow;
    }
  }

  void overrideRxCharacteristic({
    required String deviceId,
    required Uuid serviceId,
    required Uuid characteristicId,
    bool notify = true,
    bool indicate = false,
  }) {
    _rxEndpoint[deviceId] = _RxEndpoint(
      qc: QualifiedCharacteristic(
        deviceId: deviceId,
        serviceId: serviceId,
        characteristicId: characteristicId,
      ),
      notify: notify,
      indicate: indicate,
    );
    // restart subscription if already running
    _rxSubs[deviceId]?.cancel();
    _rxSubs.remove(deviceId);
    _ensureRxStreams(deviceId);
  }
}

// ---- internal types ----
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

class _RxEndpoint {
  final QualifiedCharacteristic qc;
  final bool notify;
  final bool indicate;
  _RxEndpoint({required this.qc, required this.notify, required this.indicate});
}

class _Candidate {
  final Uuid serviceId;
  final Uuid charId;
  final bool writeWithResponse;
  final bool writeWithoutResponse;
  final bool notifyMate;
  final int score;
  _Candidate({
    required this.serviceId,
    required this.charId,
    required this.writeWithResponse,
    required this.writeWithoutResponse,
    required this.notifyMate,
    required this.score,
  });
}

class _RxStreamsHolder {
  final StreamController<List<int>> bytes;
  final StreamController<String> text;
  _RxStreamsHolder({required this.bytes, required this.text});
}
