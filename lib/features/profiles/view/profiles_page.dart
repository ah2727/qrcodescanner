import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../auth/auth_service.dart';

class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final exp = auth.expiresAt;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('پروفایل کاربر'),
          actions: [
            IconButton(
              tooltip: 'خروج',
              onPressed: () async {
                await context.read<AuthService>().logout();
                // AuthGate به‌صورت خودکار به Login می‌برد
              },
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () => context.read<AuthService>().fetchMe(),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  title: Text(auth.username ?? '—'),
                  subtitle: const Text('نام کاربری'),
                  leading: const Icon(Icons.person),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  title: Text(auth.role ?? '—'),
                  subtitle: const Text('نقش'),
                  leading: const Icon(Icons.verified_user),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  title: Text(exp?.toLocal().toString() ?? '—'),
                  subtitle: const Text('انقضای توکن'),
                  leading: const Icon(Icons.timer),
                ),
              ),
              const SizedBox(height: 8),
              if (auth.me != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('اطلاعات /user: ${auth.me}'),
                  ),
                )
              else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'اطلاعات از /user در دسترس نیست؛ از JWT فقط برای نمایش استفاده شده است.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => context.read<AuthService>().logout(),
                icon: const Icon(Icons.logout),
                label: const Text('خروج از حساب'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
