import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';

class ConfigHistoryStore {
  static const boxName = 'config_history';
  static Box<String> get _box => Hive.box<String>(boxName);

  static Future<void> add({
    required String deviceId,
    required String baseUrl,
    required Map<String, dynamic> payload,
    required bool success,
    String? error,
    Map<String, dynamic>? extra,
  }) async {
    final record = {
      'deviceId': deviceId,
      'baseUrl': baseUrl,
      'payload': payload,
      'success': success,
      'error': error,
      'sentAt': DateTime.now().toIso8601String(),
      if (extra != null) 'extra': extra,
    };
    await _box.add(jsonEncode(record)); // <-- store as String
  }

  static List<Map<String, dynamic>> all() {
    return _box.values
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .toList();
  }
}
