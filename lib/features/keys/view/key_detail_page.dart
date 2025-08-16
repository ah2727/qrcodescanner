// lib/features/keys/view/key_detail_page.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qrcodescanner/storage/key_store.dart';

class KeyDetailPage extends StatelessWidget {
  final dynamic hiveKey;
  const KeyDetailPage({super.key, required this.hiveKey});

  @override
  Widget build(BuildContext context) {
    final rec = KeyStore.byHiveKey(hiveKey);
    if (rec == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Key Detail')),
        body: const Center(child: Text('Key not found')),
      );
    }
    final date = DateFormat('dd/MM/yyyy – HH:mm').format(rec.createdAt);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Key Detail'),
        actions: [
          IconButton(
            tooltip: 'Copy private key',
            icon: const Icon(Icons.key),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: rec.privateKey));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Private key copied')),
                );
              }
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            Center(
              child: QrImageView(
                data: rec.qrData,
                version: QrVersions.auto,
                size: 220,
              ),
            ),
            const SizedBox(height: 16),
            _kv('Code', rec.displayCode),
            _kv('Serial Number', rec.serialNumber),
            _kv('Created', date),
            const SizedBox(height: 8),
            Text('QR Payload', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            SelectableText(_pretty(rec.qrData)),
            const SizedBox(height: 16),
            Text('Private Key (base64)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            SelectableText(rec.privateKey),
          ],
        ),
      ),
    );
  }

  static Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600))),
          const SizedBox(width: 8),
          Expanded(child: Text(v)),
        ],
      ),
    );
  }

  static String _pretty(String raw) {
    try {
      final obj = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(obj);
    } catch (_) {
      return raw;
    }
  }
}
