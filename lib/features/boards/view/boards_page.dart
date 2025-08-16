import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/theme_controller.dart';

class BoardsPage extends StatelessWidget {
  const BoardsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Box box = Hive.box<String>('config_history'); // opened in main()

    return Scaffold(
      appBar: AppBar(
        title: const Text('Boards'),
        actions: [
          IconButton(
            tooltip: isDark ? 'Light mode' : 'Dark mode',
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            onPressed: () => context.read<ThemeController>().toggle(),
          ),
        ],
      ),
      body: ValueListenableBuilder(
        valueListenable: box.listenable(),
        builder: (_, Box<dynamic> b, __) {
          final rawItems = b.values.toList().reversed.toList(); // newest first
          final items = rawItems
              .map<Map<String, dynamic>>(_normalizeRecord)
              .where((m) => m.isNotEmpty)
              .toList();

          if (items.isEmpty) {
            return const Center(child: Text('No configurations saved yet.'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final rec = items[i];

              final payload = _asMap(rec['payload']);
              final extra   = _asMap(rec['extra']);
              final ok      = rec['success'] == true;

              final serial  = (payload?['serial_number'] ?? rec['deviceId'] ?? '-').toString();
              final project = (extra?['project'] ?? '').toString();
              final section = (extra?['location'] ?? '').toString();



              final baseUrl = (rec['baseUrl'] ?? '-').toString();
              final sentAt  = (rec['sentAt'] ?? '').toString();
              final created = _formatDate(sentAt);
              final error   = (rec['error'] ?? '').toString();

              return Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title row
                      Row(
                        children: [
                          Icon(ok ? Icons.check_circle : Icons.error, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Serial: $serial',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Section | Project
                      Text(
                        'Section: ${section.isEmpty ? '—' : section}  |  Project: ${project.isEmpty ? '—' : project}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 12),

                      // Details block

                      _kv('Project Base URL', baseUrl),
                      _kv('Created At', created.isEmpty ? '—' : created),
                      if (!ok && error.isNotEmpty) _kv('Error', error),

                      const SizedBox(height: 10),

                      // Download button
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: payload == null
                              ? null
                              : () => _downloadCfg(context, serial, payload),
                          child: const Text('Get Config File'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  // ---------- helpers ----------

  static Map<String, dynamic> _normalizeRecord(dynamic raw) {
    try {
      if (raw is String) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } else if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  static Map<String, dynamic>? _asMap(dynamic v) {
    try {
      if (v is Map) return Map<String, dynamic>.from(v);
      if (v is String) {
        final d = jsonDecode(v);
        if (d is Map) return Map<String, dynamic>.from(d);
      }
    } catch (_) {}
    return null;
  }

  static String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return DateFormat('dd/MM/yyyy - HH:mm:ss').format(dt);
    } catch (_) {
      return '';
    }
  }

  static Future<void> _downloadCfg(
    BuildContext context,
    String serial,
    Map<String, dynamic> payload,
  ) async {
    try {
      // Pretty JSON
      const encoder = JsonEncoder.withIndent('  ');
      final jsonStr = encoder.convert(payload);

      // Save to app documents
      final dir = await getApplicationDocumentsDirectory();
      final safeSerial = serial.isEmpty ? 'device' : serial;
      final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final file = File('${dir.path}/config_${safeSerial}_$ts.json');

      await file.writeAsString(jsonStr);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved: ${file.path}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }
}
Widget _kv(String k, String v) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140, // label column width
          child: Text(
            k,
            style: const TextStyle(fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(v)),
      ],
    ),
  );
}