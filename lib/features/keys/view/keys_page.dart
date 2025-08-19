import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';

import 'package:qrcodescanner/storage/key_store.dart';
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
            return const Center(child: Text('هیچ کلیدی نیست. برای ساختن، + را بزنید.'));
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final it = items[i];
              final date = DateFormat('yyyy/MM/dd  HH:mm').format(it.createdAt);
              final isUsed = it.status == 'used';

              final qrData = it.qrData.isNotEmpty
                  ? it.qrData
                  : '{"serial_number":"${it.serialNumber}"}';

              return Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      // 👇 تپ روی QR => ذخیره PNG در گالری
                      Tooltip(
                        message: 'برای دانلود QR تپ کنید',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _saveQrToGallery(context, it.serialNumber, qrData),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: QrImageView(
                                data: qrData,
                                version: QrVersions.auto,
                                errorStateBuilder: (c, e) => const Icon(Icons.qr_code_2),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(it.serialNumber,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            Text(date, style: Theme.of(context).textTheme.bodySmall),
                            const SizedBox(height: 2),
                            Text(
                              isUsed ? 'Used' : 'Newly Generated',
                              style: TextStyle(
                                color: isUsed ? Colors.grey : Colors.red,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
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
                            MaterialPageRoute(builder: (_) => KeyDetailPage(hiveKey: it.hiveKey)),
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

      // ➕ ساخت تعدادی QR
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final n = await _askHowMany(context);
          if (n == null) return;
          final made = await KeyStore.generate(n);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${made.length} key(s) generated')),
            );
          }
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<int?> _askHowMany(BuildContext context) async {
    final ctrl = TextEditingController(text: '1');
    return showDialog<int>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('چند QR Code ساخته شود؟'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: 'مثلاً: 5'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
            FilledButton(
              onPressed: () {
                final v = int.tryParse(ctrl.text.trim());
                if (v == null || v <= 0) return;
                final clamped = v > 200 ? 200 : v;
                Navigator.pop(ctx, clamped);
              },
              child: const Text('بساز'),
            ),
          ],
        );
      },
    );
  }
}

/// رندر QR به PNG بایت‌ها (سایز پیش‌فرض: 1024px)
Future<Uint8List> _renderQrPngBytes(String data, {double size = 1024}) async {
  final painter = QrPainter(
    data: data,
    version: QrVersions.auto,
    gapless: true,
    color: const Color(0xFF000000),
    emptyColor: const Color(0xFFFFFFFF),
  );

  final ui.Image img = await painter.toImage(size); // size حالا double است
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return byteData!.buffer.asUint8List();
}
/// ذخیره در گالری/Photos با نام یکتا
Future<void> _saveQrToGallery(BuildContext context, String serial, String data) async {
  try {
    final pngBytes = await _renderQrPngBytes(data, size: 1024);

    final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final safeSerial = (serial.isEmpty ? 'key' : serial).replaceAll(RegExp(r'[^\w\-]+'), '_');
    final name = 'qr_${safeSerial}_$ts';

    final result = await ImageGallerySaver.saveImage(
      pngBytes,
      quality: 100,
      name: name,
      isReturnImagePathOfIOS: true,
    );

    final ok = (result is Map && result['isSuccess'] == true);
    final path = (result is Map)
        ? (result['filePath'] ?? result['savedFilePath'] ?? result['path'])?.toString()
        : null;

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok
              ? (path != null ? 'در گالری ذخیره شد:\n$path' : 'در گالری ذخیره شد')
              : 'ذخیره ناموفق بود'),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطا در ذخیره: $e')),
      );
    }
  }
}
