import 'dart:async';
import 'dart:convert';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

/// TODO: put your real service / characteristic UUIDs here.
const String kServiceUuid = "0000abcd-0000-1000-8000-00805f9b34fb";
const String kWriteCharUuid = "0000abce-0000-1000-8000-00805f9b34fb";

class BoardBleService {
  final FlutterReactiveBle _ble;
  StreamSubscription<ConnectionStateUpdate>? _connSub;

  BoardBleService(this._ble);

  Future<void> dispose() async {
    await _connSub?.cancel();
  }

  Future<void> connect(String deviceId) async {
    await _connSub?.cancel();
    final completer = Completer<void>();
    _connSub = _ble
        .connectToDevice(
          id: deviceId,
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen((update) {
      if (update.connectionState == DeviceConnectionState.connected &&
          !completer.isCompleted) {
        completer.complete();
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

  /// Send a JSON payload to the board via a writable characteristic.
  Future<void> sendConfig({
    required String deviceId,
    required Map<String, dynamic> payload,
  }) async {
    final characteristic = QualifiedCharacteristic(
      deviceId: deviceId,
      serviceId: Uuid.parse(kServiceUuid),
      characteristicId: Uuid.parse(kWriteCharUuid),
    );
    final bytes = utf8.encode(jsonEncode(payload));
    await _ble.writeCharacteristicWithResponse(characteristic, value: bytes);
  }
}
