// lib/config/api_config.dart
import 'dart:core';
import '../auth/auth_storage.dart';
class AuthSession {
  static String? token;
  static Future<void> hydrate() async {
    token = await AuthStorage().readToken();
  }
}
/// پیکربندی و کمک‌ابزارهای API
class ApiConfig {
  ApiConfig._();

  /// آدرس بک‌اند (از dart-define بخوان، اگر نبود همین پیش‌فرض)
  /// مثال اجرا:
  /// flutter run --dart-define=API_BASE_URL=http://api.dayanpardazesh.ir:8080
  /// flutter build apk --release --dart-define=API_BASE_URL=http://api.dayanpardazesh.ir:8080
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://api.dayanpardazesh.ir:8080',
  );

  /// نسخه API
  static const String apiPrefix = '/v1';

  /// مقدار هدر APP-Auth برای /projects (از dart-define بخوان)

  /// وقتی کاربر پروژه/محل را انتخاب کرد و baseUrl مخصوص دستگاه مشخص شد،
  /// می‌توانی این را تنظیم کنی تا برای درخواست‌های بعدی به خود دستگاه استفاده شود.
  static String? _deviceBaseUrl;
  static void setDeviceBaseUrl(String base) {
    // هر نوع space/اسلش اضافی را تمیز کنیم
    final cleaned = base.trim().replaceAll(RegExp(r'/+$'), '');
    _deviceBaseUrl = cleaned;
  }

  static String? get deviceBaseUrl => _deviceBaseUrl;

  /// endpointها
  static String get login => '$apiPrefix/login';
  static String get projects => '$apiPrefix/projects';
  static String get rsaKey => '$apiPrefix/rsa-key';

  /// ساخت Uri برای بک‌اند اصلی
  static Uri apiUri(String path, [Map<String, dynamic>? query]) {
    final base = Uri.parse(baseUrl);
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: _join(base.path, path),
      queryParameters: query?.map((k, v) => MapEntry(k, v?.toString() ?? '')),
    );
  }

  /// ساخت URL رشته‌ای برای بک‌اند
  static String apiUrl(String path, [Map<String, dynamic>? query]) =>
      apiUri(path, query).toString();

  /// ساخت Uri برای دستگاه (بعد از انتخاب پروژه/محل و ست شدن baseUrl دستگاه)
  static Uri deviceUri(String path, [Map<String, dynamic>? query]) {
    final b = _deviceBaseUrl;
    if (b == null || b.isEmpty) {
      throw StateError(
        'deviceBaseUrl هنوز تنظیم نشده است. ابتدا setDeviceBaseUrl() را صدا بزن.',
      );
    }
    final base = Uri.parse(b);
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: _join(base.path, path),
      queryParameters: query?.map((k, v) => MapEntry(k, v?.toString() ?? '')),
    );
  }

  static String deviceUrl(String path, [Map<String, dynamic>? query]) =>
      deviceUri(path, query).toString();

  /// هدرهای عمومی JSON
  static Future<Map<String, String>> jsonHeadersAsync({
    Map<String, String>? extra,
    bool includeAccept = true,
  }) async {
    final token = await AuthStorage().readToken();
    return _buildJsonHeaders(
      token: token,
      extra: extra,
      includeAccept: includeAccept,
    );
  }

  /// Sync: uses cached token (call `AuthSession.hydrate()` at startup and update after login).
  static Map<String, String> jsonHeadersSync({
    String? bearer, // optional override
    Map<String, String>? extra,
    bool includeAccept = true,
  }) {
    final token = bearer ?? AuthSession.token;
    return _buildJsonHeaders(
      token: token,
      extra: extra,
      includeAccept: includeAccept,
    );
  }

  static Map<String, String> _buildJsonHeaders({
    String? token,
    Map<String, String>? extra,
    bool includeAccept = true,
  }) {
    final h = <String, String>{
      'Content-Type': 'application/json',
      if (includeAccept) 'Accept': 'application/json',
    };

    if (token != null && token.isNotEmpty) {
      h['Authorization'] = 'Bearer $token';
      h['APP-Auth'] = token; // mirror token
    }

    if (extra != null) {
      for (final e in extra.entries) {
        if (e.key.isNotEmpty && e.value.isNotEmpty) {
          // don't overwrite APP-Auth unless you mean to
          if (e.key == 'APP-Auth' && h.containsKey('APP-Auth')) continue;
          h[e.key] = e.value;
        }
      }
    }
    return h;
  }

  static Map<String, String> jsonHeaders({
    String? bearer,
    String? appAuth, // optional explicit APP-Auth
    Map<String, String>? extra,
  }) {
    final h = <String, String>{'Content-Type': 'application/json'};

    // Prefer explicit appAuth if provided; otherwise mirror the bearer.
    final tokenForHeaders = (appAuth != null && appAuth.isNotEmpty)
        ? appAuth
        : (bearer ?? '');

    if (bearer != null && bearer.isNotEmpty) {
      h['Authorization'] = 'Bearer $bearer';
    }
    if (tokenForHeaders.isNotEmpty) {
      h['APP-Auth'] = tokenForHeaders;
    }

    if (extra != null) {
      extra.forEach((k, v) {
        if (k.isEmpty || v.isEmpty) return;
        // Don't overwrite APP-Auth if we've already set it from token
        if (k == 'APP-Auth' && h.containsKey('APP-Auth')) return;
        h[k] = v;
      });
    }
    return h;
  }

  /// هدر مخصوص /projects با APP-Auth
  static Future<Map<String, String>> projectsHeaders() async {
    final token = await AuthStorage().readToken(); // ← from secure storage
    return jsonHeaders(
      bearer: token,
      extra: (token != null && token.isNotEmpty) ? {'APP-Auth': token} : null,
    );
  }

  // Helpers
  static String _join(String a, String b) {
    final left = a.endsWith('/') ? a.substring(0, a.length - 1) : a;
    final right = b.startsWith('/') ? b.substring(1) : b;
    if (left.isEmpty) return '/$right';
    return '$left/$right';
  }
}
