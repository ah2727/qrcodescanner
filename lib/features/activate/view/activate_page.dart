import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/theme_controller.dart';

class ActivatePage extends StatelessWidget {
  const ActivatePage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activate'),
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
            MaterialPageRoute(builder: (_) => const _ActivateDetail()),
          ),
          child: const Text('Open Activate detail (bottom nav persists)'),
        ),
      ),
    );
  }
}

class _ActivateDetail extends StatelessWidget {
  const _ActivateDetail({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activate Detail')),
      body: const Center(child: Text('Detail content')),
    );
  }
}
