// lib/features/boards/view/boards_page.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/theme_controller.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'dart:typed_data';
import 'package:share_plus/share_plus.dart';

class BoardsPage extends StatelessWidget {
  const BoardsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Box<String> box = Hive.box<String>('config_history'); // opened in main()

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
        builder: (_, Box b, __) {
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
              final section = (rec['section'] ?? '').toString();                // ✅ fixed
              final connectionType = (rec['connectionType'] ?? '').toString();  // ✅ fixed

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

                      // Section / Project (optional line)
                      if (project.isNotEmpty || section.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            [if (section.isNotEmpty) 'Section: $section', if (project.isNotEmpty) 'Project: $project'].join('  •  '),
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),

                      const SizedBox(height: 4),

                      // Details block
                      _kv('Connection type', connectionType),
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
    // Pretty JSON (content stays JSON; extension will be .cfg)
    const encoder = JsonEncoder.withIndent('  ');
    final jsonStr = encoder.convert(payload);

    // Suggested file name (.cfg)
    final safeSerial = serial.isEmpty ? 'device' : serial;
    final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final suggestedName = 'config_${safeSerial}_$ts.cfg';

    // helper: force .cfg extension on any chosen path
    String _forceCfgExt(String path) {
      final lastSep = path.lastIndexOf(RegExp(r'[\/\\]'));
      final lastDot = path.lastIndexOf('.');
      final hasExt = lastDot > lastSep;
      final base = hasExt ? path.substring(0, lastDot) : path;
      return '$base.cfg';
    }

    // 1) Try native "Save as..." dialog (file_selector)
    try {
      final location = await fs.getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: [fs.XTypeGroup(label: 'CFG', extensions: ['cfg'])],
      );

      if (location != null) {
        final bytes = Uint8List.fromList(utf8.encode(jsonStr));
        final xf = fs.XFile.fromData(
          bytes,
          name: suggestedName,
          // content is JSON, but file extension is .cfg
          mimeType: 'text/plain',
        );
        final targetPath = _forceCfgExt(location.path);
        await xf.saveTo(targetPath);

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved: $targetPath')),
          );
        }
        return; // done
      } else {
        // user canceled — just inform & exit
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Canceled')),
          );
        }
        return;
      }
    } catch (e) {
      // MissingPlugin/Unimplemented? fall through to fallback
    }

    // 2) Fallback: save to app documents and open share sheet (.cfg)
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$suggestedName');
    await file.writeAsString(jsonStr);

    // optional share so user can pick destination (Files/Drive/etc.)
    try {
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/plain', name: suggestedName)],
        text: 'Configuration file',
      );
    } catch (_) {}

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to app documents: ${file.path}')),
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
