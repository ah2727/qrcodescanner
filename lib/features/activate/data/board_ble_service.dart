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

  /// Connects, waits briefly, discovers services, auto-picks a writable char, negotiates MTU.
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
          // Small delay helps some stacks stabilize before discovery.
          await Future<void>.delayed(const Duration(milliseconds: 300));

          final services = await _ble.discoverServices(deviceId);
          _servicesCache[deviceId] = services;

          if (kDebugMode) {
            debugPrint(await gattTable(deviceId));
          }

          _writeEndpoint[deviceId] = _pickWritableEndpoint(deviceId, services);

          try {
            // iOS ignores this; Android can raise up to 517, but 247 is widely supported.
            final mtu = await _ble.requestMtu(deviceId: deviceId, mtu: 247);
            _mtuCache[deviceId] = mtu;
          } catch (_) {
            // Ignore; we'll chunk safely.
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

  /// Sends a JSON payload to the board (chunked & retried if needed).
  Future<void> sendConfig({
    required String deviceId,
    required Map<String, dynamic> payload,
  }) async {
    final endpoint = await _ensureWriteEndpoint(deviceId);

    // Encode JSON
    final data = Uint8List.fromList(utf8.encode(jsonEncode(payload)));

    // Compute safe chunk size (iOS ~20 bytes, Android = MTU-3 if known)
    final mtu = _mtuCache[deviceId];
    final maxChunk =
        Platform.isIOS ? 20 : ((mtu != null && mtu > 3) ? (mtu - 3) : 20);

    // Attempt write; on certain GATT failures (e.g., 133), do ONE reconnect+retry.
    try {
      await _writeChunked(endpoint, data, maxChunk: maxChunk);
    } catch (e) {
      if (_looksLikeTransientGatt(e)) {
        // Retry once: disconnect -> wait -> reconnect -> rediscover -> re-pick endpoint -> write again
        try {
          await disconnect();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await connect(deviceId);
          final ep2 = await _ensureWriteEndpoint(deviceId);
          await _writeChunked(ep2, data, maxChunk: maxChunk);
          return;
        } catch (ee) {
          rethrow; // surface second failure
        }
      }
      rethrow;
    }
  }

  // ---------------- Internals ----------------

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
    DiscoveredService? chosenSvc;
    DiscoveredCharacteristic? chosenChar;

    // Prefer writeWithoutResponse for speed if available…
    for (final s in services) {
      for (final c in s.characteristics) {
        if (c.isWritableWithoutResponse) {
          chosenSvc = s;
          chosenChar = c;
          break;
        }
      }
      if (chosenChar != null) break;
    }

    // …otherwise use write-with-response.
    if (chosenChar == null) {
      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.isWritableWithResponse) {
            chosenSvc = s;
            chosenChar = c;
            break;
          }
        }
        if (chosenChar != null) break;
      }
    }

    if (chosenSvc == null || chosenChar == null) {
      throw Exception(
        'No writable characteristic found.\n'
        'Tip: verify with nRF Connect that the device exposes a writable characteristic.',
      );
    }

    return _WriteEndpoint(
      qc: QualifiedCharacteristic(
        deviceId: deviceId,
        serviceId: chosenSvc.serviceId,
        characteristicId: chosenChar.characteristicId,
      ),
      writeWithResponse: chosenChar.isWritableWithResponse,
      writeWithoutResponse: chosenChar.isWritableWithoutResponse,
    );
  }

  Future<void> _writeChunked(
    _WriteEndpoint endpoint,
    Uint8List data, {
    required int maxChunk,
  }) async {
    if (data.length <= maxChunk) {
      await _writeWithFallback(endpoint, data);
      return;
    }
    for (int i = 0; i < data.length; i += maxChunk) {
      final end = (i + maxChunk < data.length) ? i + maxChunk : data.length;
      final chunk = data.sublist(i, end);
      await _writeWithFallback(endpoint, chunk);
      await Future<void>.delayed(const Duration(milliseconds: 15)); // pacing
    }
  }

  /// Try WITH RESPONSE first when both are advertised (more compatible),
  /// fall back to WITHOUT RESPONSE once if the first attempt fails.
  Future<void> _writeWithFallback(
    _WriteEndpoint endpoint,
    List<int> value,
  ) async {
    final both = endpoint.writeWithResponse && endpoint.writeWithoutResponse;

    Future<void> wRsp() =>
        _ble.writeCharacteristicWithResponse(endpoint.qc, value: value);
    Future<void> wNoRsp() =>
        _ble.writeCharacteristicWithoutResponse(endpoint.qc, value: value);

    try {
      if (both) {
        await wRsp();
        return;
      }
      if (endpoint.writeWithResponse) {
        await wRsp();
        return;
      }
      if (endpoint.writeWithoutResponse) {
        await wNoRsp();
        return;
      }
      throw Exception('Resolved characteristic is not writable.');
    } catch (e) {
      if (both) {
        // Try the other mode once
        try {
          await wNoRsp();
          return;
        } catch (_) {
          // fall through to rethrow below
        }
      }
      debugPrint(
        'BLE write failed on ${endpoint.qc.serviceId}/${endpoint.qc.characteristicId}: $e',
      );
      rethrow;
    }
  }

  bool _looksLikeTransientGatt(Object e) {
    final msg = e.toString().toLowerCase();
    // Heuristics: Android "133", generic "gatt" error, or "status" hints.
    return msg.contains('133') ||
        msg.contains('gatt') ||
        msg.contains('status') ||
        msg.contains('timeout');
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
