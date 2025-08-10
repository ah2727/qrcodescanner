// lib/features/activation/data/board_ble_service.dart
import 'dart:async';
import 'dart:convert';
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
          // small delay helps flaky stacks
          await Future<void>.delayed(const Duration(milliseconds: 300));

          final services = await _ble.discoverServices(deviceId);
          _servicesCache[deviceId] = services;

          // Log GATT table once on connect (comment out later)
          if (kDebugMode) {
            debugPrint(await gattTable(deviceId));
          }

          _writeEndpoint[deviceId] = _pickWritableEndpoint(deviceId, services);

          try {
            final mtu = await _ble.requestMtu(deviceId: deviceId, mtu: 247);
            _mtuCache[deviceId] = mtu;
          } catch (_) {
            // iOS ignores; some stacks fail -> fine
          }

          completer.complete();
        } catch (e) {
          completer.completeError(e);
        }
      }

      // Surface connection failures
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

  Future<void> sendConfig({
    required String deviceId,
    required Map<String, dynamic> payload,
  }) async {
    final endpoint = await _ensureWriteEndpoint(deviceId);

    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final mtu = _mtuCache[deviceId];
    final maxChunk = (mtu != null && mtu > 3) ? (mtu - 3) : 20;

    if (bytes.length <= maxChunk) {
      await _write(endpoint, bytes);
      return;
    }

    for (final chunk in _chunk(bytes, maxChunk)) {
      await _write(endpoint, chunk);
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  // ---------- internals ----------

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

    // Prefer writeWithoutResponse
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

    // Fallback to write-with-response
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
        'Tip: open nRF Connect and verify the device exposes a writable GATT characteristic.',
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

  Future<void> _write(_WriteEndpoint endpoint, List<int> value) async {
    try {
      if (endpoint.writeWithoutResponse) {
        await _ble.writeCharacteristicWithoutResponse(endpoint.qc, value: value);
      } else if (endpoint.writeWithResponse) {
        await _ble.writeCharacteristicWithResponse(endpoint.qc, value: value);
      } else {
        throw Exception('Resolved characteristic is not writable.');
      }
    } catch (e) {
      // Surface GATT errors with context (very helpful when debugging)
      debugPrint('BLE write failed on ${endpoint.qc.serviceId}/${endpoint.qc.characteristicId}: $e');
      rethrow;
    }
  }

  List<List<int>> _chunk(Uint8List data, int maxLen) {
    final out = <List<int>>[];
    for (int i = 0; i < data.length; i += maxLen) {
      final end = (i + maxLen < data.length) ? i + maxLen : data.length;
      out.add(data.sublist(i, end));
    }
    return out;
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
