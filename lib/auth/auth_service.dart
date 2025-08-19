import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jwt_decoder/jwt_decoder.dart';

class AuthService extends ChangeNotifier {
  static const _tokenKey = 'token';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final Dio dio;

  String? _token;
  Map<String, dynamic>? _me; // {username, role, ...}

  /// آدرس بک‌اند (با امکان override در بیلد)
  /// مثالِ بیلد:
  /// flutter run --dart-define=API_URL=https://api.example.com/v1/
  static const String baseUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'http://api.dayanpardazesh.ir:8080/v1/',
  );

  /// مسیرها را نسبی نگه دارید (بدون / ابتدا) تا انتهای baseUrl حذف نشود.
  static const String _loginPath = 'auth/login';
  static const String _mePath = 'user';

  AuthService()
      : dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 20),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
          ),
        ) {
    // اینترسپتور: اضافه کردن توکن‌ها و مدیریت 401
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (_token != null && _token!.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $_token';
            options.headers['APP-Auth'] = _token; // بدون Bearer
          }
          handler.next(options);
        },
        onError: (err, handler) async {
          if (err.response?.statusCode == 401) {
            await logout();
          }
          handler.next(err);
        },
      ),
    );
  }

  // ---------- Getters ----------
  bool get isLoggedIn =>
      _token != null && _token!.isNotEmpty && !JwtDecoder.isExpired(_token!);

  String? get token => _token;
  Map<String, dynamic>? get me => _me;

  String? get role {
    if (_me?['role'] != null) return _me!['role']?.toString();
    final p = jwtPayload;
    return p?['role']?.toString();
    }

  String? get username {
    if (_me?['username'] != null) return _me!['username']?.toString();
    final p = jwtPayload;
    return p?['username']?.toString();
  }

  DateTime? get expiresAt =>
      _token == null ? null : JwtDecoder.getExpirationDate(_token!);

  Map<String, dynamic>? get jwtPayload {
    if (_token == null) return null;
    try {
      return JwtDecoder.decode(_token!);
    } catch (_) {
      return null;
    }
  }

  // ---------- Lifecycle ----------
  /// هنگام بالا آمدن اپ صدا بزن
  Future<void> init() async {
    _token = await _storage.read(key: _tokenKey);
    if (_token != null && JwtDecoder.isExpired(_token!)) {
      await logout();
      return;
    }
    if (_token != null) {
      await fetchMe(); // تلاش برای گرفتن پروفایل
    }
    notifyListeners();
  }

  // ---------- Auth ----------
  Future<void> login({
    required String username,
    required String password,
  }) async {
    final res = await dio.post(
      _loginPath,
      data: {'username': username, 'password': password},
    );

    final dynamic raw = res.data;
    final Map<String, dynamic> data =
        raw is Map<String, dynamic> ? raw : Map<String, dynamic>.from(json.decode(raw as String));

    final String? tk = _extractToken(data);
    if (tk == null || tk.isEmpty) {
      throw Exception('No token in response');
    }

    _token = tk;
    await _storage.write(key: _tokenKey, value: _token);

    // چک انقضا
    if (JwtDecoder.isExpired(_token!)) {
      await logout();
      throw Exception('Token is expired');
    }

    await fetchMe(); // نقش و نام کاربری
    notifyListeners();
  }

  /// /v1/user را می‌خواند و اطلاعات را در _me می‌گذارد
  Future<void> fetchMe() async {
    try {
      final res = await dio.get(_mePath); // هدرها از اینترسپتور اضافه می‌شوند
      final data = res.data;
      _me = (data is Map) ? Map<String, dynamic>.from(data) : null;
    } catch (_) {
      _me = null;
    }
    notifyListeners();
  }

  Future<void> logout() async {
    _token = null;
    _me = null;
    await _storage.delete(key: _tokenKey);
    notifyListeners();
  }

  // ---------- Helpers ----------
  /// انعطاف در استخراج توکن از پاسخ‌های مختلف
  String? _extractToken(Map<String, dynamic> data) {
    if (data['token'] is String) return data['token'] as String;
    if (data['accessToken'] is String) return data['accessToken'] as String;
    final d = data['data'];
    if (d is Map<String, dynamic>) {
      if (d['token'] is String) return d['token'] as String;
      if (d['accessToken'] is String) return d['accessToken'] as String;
    }
    return null;
  }
}
