import 'package:flutter/material.dart';
import '../app/app_shell.dart';
import 'login_page.dart';
import 'auth_storage.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthStorage(); // <-- no const

    return FutureBuilder<String?>(
      future: auth.readToken(), // <-- use the instance
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final hasToken = (snap.data ?? '').isNotEmpty;
        return hasToken ? const AppShell() : const LoginPage();
      },
    );
  }
}
