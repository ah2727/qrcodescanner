import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

class BleScanner extends ChangeNotifier {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  StreamSubscription<DiscoveredDevice>? _sub;
  final Map<String, DiscoveredDevice> _devices = {};
  bool _scanning = false;
  bool _permissionsOk = false;
  BleStatus _status = BleStatus.unknown;

  /// اگر خواستی «unknown»ها را نشان بدهی، این را false کن
  final bool hideUnknown = true;

  BleScanner() {
    _status = _ble.status;
    _ble.statusStream.listen((s) {
      _status = s;
      notifyListeners();
    });
  }

  bool get scanning => _scanning;
  BleStatus get status => _status;

  /// لیست مرتب‌شده بر اساس RSSI (unknownها حذف شده‌اند)
  List<DiscoveredDevice> get devices {
    final list = _devices.values
        .where((d) => !hideUnknown || !_isUnknown(d))
        .toList()
      ..sort((a, b) => (b.rssi).compareTo(a.rssi));
    return list;
  }

  Future<void> ensurePermissions() async {
    final req = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    _permissionsOk = req.values.every((s) => s.isGranted);
    notifyListeners();
  }

  Future<void> startScan() async {
    if (_scanning) return;
    await ensurePermissions();
    if (!_permissionsOk) return;

    _devices.clear();
    _scanning = true;
    notifyListeners();

    _sub = _ble
        .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
        .listen((d) {
      // حذف Unknown ها
      if (!_isUnknown(d)) {
        _devices[d.id] = d; // de-duplicate by ID
        notifyListeners();
      }
      // نکته: اگر الان unknown بود و بعداً name گرفت، دوباره ایونت می‌آید و اضافه می‌شود.
    }, onError: (e) {
      _scanning = false;
      notifyListeners();
    });
  }

  Future<void> stopScan() async {
    await _sub?.cancel();
    _sub = null;
    _scanning = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// تشخیص Unknown بودن دیوایس:
  /// - name خالی یا فقط فاصله
  /// - یا برابر با "unknown"/"unknown device"/"n/a"/"null" (حروف کوچک/بزرگ مهم نیست)
  bool _isUnknown(DiscoveredDevice d) {
    final n = (d.name).trim();
    if (n.isEmpty) return true;
    final lower = n.toLowerCase();
    if (lower == 'unknown' ||
        lower == 'unknown device' ||
        lower == 'n/a' ||
        lower == 'null') {
      return true;
    }
    return false;
  }
}
