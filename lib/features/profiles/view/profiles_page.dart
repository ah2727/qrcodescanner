import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/theme_controller.dart';

class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profiles'),
        actions: [
          IconButton(
            tooltip: isDark ? 'Light mode' : 'Dark mode',
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            onPressed: () => context.read<ThemeController>().toggle(),
          ),
        ],
      ),
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const _ProfilesDetail()),
          ),
          child: const Text('Open profile detail'),
        ),
      ),
    );
  }
}

class _ProfilesDetail extends StatelessWidget {
  const _ProfilesDetail({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile Detail')),
      body: const Center(child: Text('Profile details here')),
    );
  }
}
