import 'package:flutter/material.dart';
import '../app/app_shell.dart';
import 'login_page.dart';
import 'auth_storage.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = AuthStorage();
    return FutureBuilder<bool>(
      future: storage.isLoggedIn(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return (snap.data ?? false) ? const AppShell() : const LoginPage();
      },
    );
  }
}
