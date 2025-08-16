import 'dart:convert';
import 'dart:math';
import 'package:hive_flutter/hive_flutter.dart';

const String kKeysBox = 'keys_box';

class KeyRecord {
  final dynamic hiveKey;
  final String id;
  final String displayCode;
  final String qrData;
  final String serialNumber;
  final String privateKey;
  final DateTime createdAt;

  KeyRecord({
    required this.hiveKey,
    required this.id,
    required this.displayCode,
    required this.qrData,
    required this.serialNumber,
    required this.privateKey,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'displayCode': displayCode,
        'qrData': qrData,
        'serialNumber': serialNumber,
        'privateKey': privateKey,
        'createdAt': createdAt.toIso8601String(),
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
      return KeyRecord(
        hiveKey: hiveKey,
        id: (m['id'] ?? '') as String,
        displayCode: (m['displayCode'] ?? '') as String,
        qrData: (m['qrData'] ?? '') as String,
        serialNumber: (m['serialNumber'] ?? '') as String,
        privateKey: (m['privateKey'] ?? '') as String,
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}

class KeyStore {
  static Box get _box => Hive.box(kKeysBox);
  static final _r = Random.secure();

  /// Use this for your "Get RSA Keys" *generator* flow (keeps random UI code).
  static Future<KeyRecord> addFromConfigPayload(Map<String, dynamic> payload) async {
    final serial = (payload['serial_number'] ?? '').toString();
    final priv   = (payload['private_key'] ?? '').toString();
    if (serial.isEmpty || priv.isEmpty) {
      throw ArgumentError('payload must include serial_number and private_key');
    }

    final rec = _buildRecordRandom(
      serialNumber: serial,
      privateKey: priv,
      qrData: jsonEncode({'serial_number': serial, 'private_key': priv}),
    );

    final hiveKey = await _box.add(jsonEncode(rec.toMap()));
    return KeyRecord(
      hiveKey: hiveKey,
      id: rec.id,
      displayCode: rec.displayCode,
      qrData: rec.qrData,
      serialNumber: rec.serialNumber,
      privateKey: rec.privateKey,
      createdAt: rec.createdAt,
    );
  }

  /// ✅ Use this from activation_sheet: no randoms, upsert by serial_number.
  static Future<KeyRecord> upsertFromConfigPayload(Map<String, dynamic> payload) async {
    final serial = (payload['serial_number'] ?? '').toString();
    final priv   = (payload['private_key'] ?? '').toString();
    if (serial.isEmpty || priv.isEmpty) {
      throw ArgumentError('payload must include serial_number and private_key');
    }

    // Find existing record by serial
    final existing = _findBySerial(serial);

    final now = DateTime.now();
    final qr = jsonEncode({'serial_number': serial, 'private_key': priv});

    if (existing != null) {
      // Update in place: keep id/displayCode, refresh key & timestamp
      final updatedMap = {
        'id': existing.id,
        'displayCode': existing.displayCode,
        'qrData': qr,
        'serialNumber': serial,
        'privateKey': priv,
        'createdAt': now.toIso8601String(),
      };
      await _box.put(existing.hiveKey, jsonEncode(updatedMap));
      return KeyRecord.fromAny(existing.hiveKey, updatedMap)!;
    }

    // Not found: create deterministic record (no random)
    final deterministic = KeyRecord(
      hiveKey: null,
      id: serial, // stable id
      displayCode: _deriveDisplayFromSerial(serial),
      qrData: qr,
      serialNumber: serial,
      privateKey: priv,
      createdAt: now,
    );
    final hiveKey = await _box.add(jsonEncode(deterministic.toMap()));
    return KeyRecord.fromAny(hiveKey, deterministic.toMap())!;
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

  // ---- helpers ----

  /// Random flavor used by the "generate" flow (kept for the Keys page FAB, etc.)
  static KeyRecord _buildRecordRandom({
    required String serialNumber,
    required String privateKey,
    required String qrData,
  }) {
    return KeyRecord(
      hiveKey: null,
      id: _randBase36(16),
      displayCode: _randBase62(8),
      qrData: qrData,
      serialNumber: serialNumber,
      privateKey: privateKey,
      createdAt: DateTime.now(),
    );
  }

  static String _deriveDisplayFromSerial(String serial) {
    final s = serial.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (s.length >= 8) return s.substring(0, 8);
    return s.padRight(8, '0'); // make it 8 chars for consistent UI
  }

  static KeyRecord? _findBySerial(String serial) {
    for (final e in _box.toMap().entries) {
      final rec = KeyRecord.fromAny(e.key, e.value);
      if (rec != null && rec.serialNumber == serial) return rec;
    }
    return null;
  }

  static String _randBase36(int len) {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    return List.generate(len, (_) => chars[_r.nextInt(chars.length)]).join();
  }

  static String _randBase62(int len) {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    return List.generate(len, (_) => chars[_r.nextInt(chars.length)]).join();
  }
}
