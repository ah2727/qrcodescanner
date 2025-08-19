// lib/storage/config_history_store.dart
import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';

class ConfigHistoryStore {
  static const _boxName = 'config_history';
  static Box<String> get _box => Hive.box<String>(_boxName);

  /// Call once at app start (before using the store)
  static Future<void> init() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox<String>(_boxName);
    }
  }

  /// Save a send-config record (stored as JSON string in Hive).
  /// [section] and [connectionType] are now supported.
  static Future<void> add({
    required String deviceId,
    required String baseUrl,
    required Map<String, dynamic> payload,
    required bool success,
    String? error,
    Map<String, dynamic>? extra,
    String? section,
    String? connectionType,
  }) async {
    final record = <String, dynamic>{
      'deviceId': deviceId,
      'baseUrl': baseUrl,
      'payload': payload,
      'success': success,
      'error': error,
      'sentAt': DateTime.now().toIso8601String(),
      if (extra != null) 'extra': extra,
      if (section != null) 'section': section,
      if (connectionType != null) 'connectionType': connectionType,
    };
    await _box.add(jsonEncode(record));
  }

  /// All decoded records as List<Map<String, dynamic>>.
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

  /// Latest record for a device.
  /// You can filter by [onlySuccess], [section], and/or [connectionType].
  static Map<String, dynamic>? lastRecordForDevice(
    String deviceId, {
    bool onlySuccess = true,
    String? section,
    String? connectionType,
  }) {
    final items = all()
        .where((m) => (m['deviceId'] ?? '') == deviceId)
        .where((m) => !onlySuccess || m['success'] == true)
        .where((m) => section == null || (m['section'] ?? '') == section)
        .where((m) => connectionType == null || (m['connectionType'] ?? '') == connectionType)
        .toList()
      ..sort((a, b) {
        final da = DateTime.tryParse(a['sentAt'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final db = DateTime.tryParse(b['sentAt'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return db.compareTo(da); // newest first
      });

    return items.isEmpty ? null : items.first;
  }

  /// Latest payload for a device as Map (with the same optional filters).
  static Map<String, dynamic>? lastPayloadForDevice(
    String deviceId, {
    bool onlySuccess = true,
    String? section,
    String? connectionType,
  }) {
    final rec = lastRecordForDevice(
      deviceId,
      onlySuccess: onlySuccess,
      section: section,
      connectionType: connectionType,
    );
    final p = rec?['payload'];
    return (p is Map) ? Map<String, dynamic>.from(p) : null;
  }
}
