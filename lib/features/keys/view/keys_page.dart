// lib/features/keys/view/keys_page.dart
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:qrcodescanner/storage/key_store.dart';
import 'package:qrcodescanner/storage/config_history_store.dart';
import 'package:qrcodescanner/features/keys/view/key_detail_page.dart';
import '../../../core/theme/theme_controller.dart';

class KeysPage extends StatelessWidget {
  const KeysPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final box = Hive.box(kKeysBox);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Keys'),
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
          final items = KeyStore.allSortedDesc();
          if (items.isEmpty) {
            return const Center(
              child: Text('No keys yet. Tap + to add from history.'),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final it = items[i];
              final date = DateFormat('dd/MM/yyyy').format(it.createdAt);
              return Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: QrImageView(
                            data: _miniQrData(it), // <<< use short data
                            version: QrVersions.auto,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              it.displayCode,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              date,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              'Newly Generated',
                              style: TextStyle(
                                color: Colors.red,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'View',
                        icon: const Icon(Icons.chevron_right),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  KeyDetailPage(hiveKey: it.hiveKey),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await KeyStore.delete(it.hiveKey);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Key deleted')),
                            );
                          }
                        },
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
}

Future<String?> _pickDeviceIdFromHistory(BuildContext context) async {
  final records = ConfigHistoryStore.all(); // List<Map<String, dynamic>>
  final items = <_DeviceItem>[];

  for (final r in records) {
    final id = (r['deviceId'] ?? '').toString();
    if (id.isEmpty) continue;
    final sentAt = DateTime.tryParse(r['sentAt']?.toString() ?? '');
    final project = (r['extra'] is Map) ? (r['extra']['project'] ?? '') : '';
    final location = (r['extra'] is Map) ? (r['extra']['location'] ?? '') : '';
    items.add(
      _DeviceItem(
        id: id,
        sentAt: sentAt,
        project: '$project',
        location: '$location',
      ),
    );
  }

  items.sort(
    (a, b) => (b.sentAt ?? DateTime(0)).compareTo(a.sentAt ?? DateTime(0)),
  );
  final unique = <String, _DeviceItem>{};
  for (final it in items) {
    unique.putIfAbsent(it.id, () => it);
  }
  final list = unique.values.toList();

  if (list.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No devices in config history')),
      );
    }
    return null;
  }
  if (list.length == 1) return list.first.id;

  return showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Select device'),
      children: list.map((it) {
        final meta = [
          if (it.project.isNotEmpty) it.project,
          if (it.location.isNotEmpty) it.location,
        ].join(' • ');
        final dateStr = it.sentAt?.toLocal().toString().split('.').first ?? '';
        return SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, it.id),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(it.id, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (meta.isNotEmpty)
                Text(meta, style: const TextStyle(fontSize: 12)),
              if (dateStr.isNotEmpty)
                Text(dateStr, style: const TextStyle(fontSize: 12)),
            ],
          ),
        );
      }).toList(),
    ),
  );
}
String _miniQrData(KeyRecord r) {
  // Prefer a short, stable ID for the small preview.
  // You can choose what you want to encode:
  // - r.serialNumber
  // - r.displayCode (8 chars)
  // - 'key:${r.displayCode}'
  return (r.serialNumber.isNotEmpty) ? r.serialNumber : r.displayCode;
}
class _DeviceItem {
  final String id;
  final DateTime? sentAt;
  final String project;
  final String location;
  _DeviceItem({
    required this.id,
    this.sentAt,
    required this.project,
    required this.location,
  });
}
