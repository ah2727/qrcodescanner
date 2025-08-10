// lib/config/api_config.dart
import 'dart:core';

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
  /// نکته: مقدار پیش‌فرض را حتماً در محیط واقعی عوض کن.
  static const String appAuth = String.fromEnvironment(
    'APP_AUTH',
    defaultValue: 'S3cr3t-ChangeThis-To-A-Long-Random-String-#1234567890@!',
  );

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
  static String get login   => '$apiPrefix/login';
  static String get projects=> '$apiPrefix/projects';
  static String get rsaKey  => '$apiPrefix/rsa-key';

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
      throw StateError('deviceBaseUrl هنوز تنظیم نشده است. ابتدا setDeviceBaseUrl() را صدا بزن.');
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
  static Map<String, String> jsonHeaders({
    String? bearer,                      // اگر توکن داشتی
    Map<String, String>? extra,          // هدر اضافه (مثل APP-Auth)
  }) {
    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (bearer != null && bearer.isNotEmpty) 'Authorization': 'Bearer $bearer',
      if (extra != null) ...extra,
    };
  }

  /// هدر مخصوص /projects با APP-Auth
  static Map<String, String> projectsHeaders({String? bearer}) =>
      jsonHeaders(bearer: bearer, extra: {'APP-Auth': appAuth});

  // Helpers
  static String _join(String a, String b) {
    final left  = a.endsWith('/') ? a.substring(0, a.length - 1) : a;
    final right = b.startsWith('/') ? b.substring(1) : b;
    if (left.isEmpty) return '/$right';
    return '$left/$right';
  }
}
