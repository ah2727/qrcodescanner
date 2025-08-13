import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthStorage {
  static const _kUser = 'user_profile';
  static const _storage = FlutterSecureStorage();

  Future<void> saveUser({required String username, required String role}) async {
    final jsonStr = jsonEncode({'username': username, 'role': role});
    await _storage.write(key: _kUser, value: jsonStr);
  }

  Future<Map<String, dynamic>?> readUser() async {
    final raw = await _storage.read(key: _kUser);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map;
    } catch (_) {
      return null;
    }
  }

  Future<bool> isLoggedIn() async {
    final u = await readUser();
    final name = u?['username'] as String?;
    return name != null && name.isNotEmpty;
  }

  Future<void> clear() => _storage.delete(key: _kUser);
}
