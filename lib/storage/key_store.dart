import 'dart:convert';
import 'dart:math';
import 'package:hive_flutter/hive_flutter.dart';

const String kKeysBox = 'keys_box';

class KeyRecord {
  final dynamic hiveKey;
  final String id;              // حالا برای کلیدهای تولیدی = serial
  final String displayCode;     // برای لیست؛ اینجا = serial
  final String qrData;          // JSON کوتاه: {"serial_number": "..."}
  final String serialNumber;    // سریال 6کاراکتری
  final String privateKey;      // ممکن است خالی بماند
  final DateTime createdAt;
  final String status;          // "new" | "used"

  KeyRecord({
    required this.hiveKey,
    required this.id,
    required this.displayCode,
    required this.qrData,
    required this.serialNumber,
    required this.privateKey,
    required this.createdAt,
    required this.status,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'displayCode': displayCode,
        'qrData': qrData,
        'serialNumber': serialNumber,
        'privateKey': privateKey,
        'createdAt': createdAt.toIso8601String(),
        'status': status,
      };

  static KeyRecord? fromAny(dynamic hiveKey, dynamic raw) {
    try {
      Map<String, dynamic> m;
      if (raw is String) {
        final d = jsonDecode(raw);
        if (d is! Map) return null;
        m = Map<String, dynamic>.from(d);
      } else if (raw is Map) {
        m = Map<String, dynamic>.from(raw);
      } else {
        return null;
      }

      final privateKey = (m['privateKey'] ?? '').toString();
      final status = (m['status'] ?? (privateKey.isNotEmpty ? 'used' : 'new')).toString();

      return KeyRecord(
        hiveKey: hiveKey,
        id: (m['id'] ?? '') as String,
        displayCode: (m['displayCode'] ?? '') as String,
        qrData: (m['qrData'] ?? '') as String,
        serialNumber: (m['serialNumber'] ?? '') as String,
        privateKey: privateKey,
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
        status: status,
      );
    } catch (_) {
      return null;
    }
  }
}

class KeyStore {
  static Box get _box => Hive.box(kKeysBox);
  static final _r = Random.secure();

  /// تولید N کلید با سریال 6 کاراکتری (حروف کوچک/بزرگ + عدد)، بدون private_key.
  /// اگر سریالی از قبل وجود داشته باشد، برای آن یک سریال جدید تولید می‌شود.
  static Future<List<KeyRecord>> generate(int count) async {
    final created = <KeyRecord>[];
    for (var i = 0; i < count; i++) {
      final serial = _uniqueSerial6();
      final qr = jsonEncode({'serial_number': serial});

      final recMap = {
        'id': serial,                // پایدار و معنادار
        'displayCode': serial,       // در لیست نشان داده می‌شود
        'qrData': qr,
        'serialNumber': serial,
        'privateKey': '',            // فعلاً خالی
        'createdAt': DateTime.now().toIso8601String(),
        'status': 'new',             // Newly Generated
      };

      final hiveKey = await _box.add(jsonEncode(recMap));
      created.add(KeyRecord.fromAny(hiveKey, recMap)!);
    }
    return created;
  }

  /// وقتی دستگاه با این سریال کانفیگ شد، وضعیت را used کن.
  static Future<void> markUsedBySerial(String serial) async {
    final entry = _findEntryBySerial(serial);
    if (entry == null) return;
    final (hk, rec) = entry;

    final updated = rec.toMap()
      ..['status'] = 'used'
      ..['createdAt'] = DateTime.now().toIso8601String(); // یا می‌توانید usedAt جداگانه بگذارید

    await _box.put(hk, jsonEncode(updated));
  }

  /// اگر بعداً از سمت اکتیویشن، private_key هم آمد، همان رکورد را کامل کن و used بزن.
  static Future<void> attachPrivateKeyAndUse(String serial, String privateKey) async {
    final entry = _findEntryBySerial(serial);
    if (entry == null) return;
    final (hk, rec) = entry;

    final qr = jsonEncode({'serial_number': serial, 'private_key': privateKey});
    final updated = rec.toMap()
      ..['privateKey'] = privateKey
      ..['qrData'] = qr
      ..['status'] = 'used';

    await _box.put(hk, jsonEncode(updated));
  }

  static Future<void> delete(dynamic hiveKey) => _box.delete(hiveKey);

  static List<KeyRecord> allSortedDesc() {
    final list = _box.toMap().entries
        .map((e) => KeyRecord.fromAny(e.key, e.value))
        .where((e) => e != null)
        .cast<KeyRecord>()
        .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  static KeyRecord? byHiveKey(dynamic hiveKey) {
    if (!_box.containsKey(hiveKey)) return null;
    return KeyRecord.fromAny(hiveKey, _box.get(hiveKey));
  }

  // --- helpers ---

  static (dynamic, KeyRecord)? _findEntryBySerial(String serial) {
    for (final e in _box.toMap().entries) {
      final rec = KeyRecord.fromAny(e.key, e.value);
      if (rec != null && rec.serialNumber == serial) {
        return (e.key, rec);
      }
    }
    return null;
  }

  static String _uniqueSerial6() {
    String s;
    do {
      s = _randSerial6();
    } while (_existsSerial(s));
    return s;
  }

  static bool _existsSerial(String serial) {
    for (final e in _box.values) {
      final rec = KeyRecord.fromAny(null, e);
      if (rec != null && rec.serialNumber == serial) return true;
    }
    return false;
  }

  static String _randSerial6() {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    return List.generate(6, (_) => chars[_r.nextInt(chars.length)]).join();
  }
}
