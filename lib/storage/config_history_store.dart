// lib/storage/config_history_store.dart
import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';

class ConfigHistoryStore {
  static const _boxName = 'config_history';
  static Box<String> get _box => Hive.box<String>(_boxName);

  /// Save a send-config record (JSON string in Hive).
  static Future<void> add({
    required String deviceId,
    required String baseUrl,
    required Map<String, dynamic> payload,
    required bool success,
    String? error,
    Map<String, dynamic>? extra,
  }) async {
    final record = <String, dynamic>{
      'deviceId': deviceId,
      'baseUrl': baseUrl,
      'payload': payload,
      'success': success,
      'error': error,
      'sentAt': DateTime.now().toIso8601String(),
      if (extra != null) 'extra': extra,
    };
    await _box.add(jsonEncode(record));
  }

  /// All decoded records as Map<String, dynamic>.
  static List<Map<String, dynamic>> all() {
    return _box.values.map((s) {
      try {
        final m = jsonDecode(s);
        return (m is Map) ? Map<String, dynamic>.from(m) : <String, dynamic>{};
      } catch (_) {
        return <String, dynamic>{};
      }
    }).where((m) => m.isNotEmpty).toList();
  }

  /// Latest record for a device (optionally success only).
  static Map<String, dynamic>? lastRecordForDevice(String deviceId, {bool onlySuccess = true}) {
    final items = all()
        .where((m) => (m['deviceId'] ?? '') == deviceId)
        .where((m) => !onlySuccess || m['success'] == true)
        .toList()
      ..sort((a, b) {
        final da = DateTime.tryParse(a['sentAt'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final db = DateTime.tryParse(b['sentAt'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        return db.compareTo(da); // newest first
      });
    return items.isEmpty ? null : items.first;
  }

  /// Latest payload for a device as Map.
  static Map<String, dynamic>? lastPayloadForDevice(String deviceId, {bool onlySuccess = true}) {
    final rec = lastRecordForDevice(deviceId, onlySuccess: onlySuccess);
    final p = rec?['payload'];
    return (p is Map) ? Map<String, dynamic>.from(p) : null;
  }
}
