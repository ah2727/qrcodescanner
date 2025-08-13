import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../activate/controller/ble_scanner.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import './activation_sheet.dart';
import '../../../storage/config_history_store.dart';

class ActivatePage extends StatelessWidget {
  const ActivatePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => BleScanner(),
      child: const _ActivateView(),
    );
  }
}

class _ActivateView extends StatelessWidget {
  const _ActivateView();

  String _bleLabel(BleStatus status) {
    switch (status) {
      case BleStatus.ready: return "PoweredOn";
      case BleStatus.unauthorized: return "Unauthorized";
      case BleStatus.poweredOff: return "PoweredOff";
      case BleStatus.locationServicesDisabled: return "Location Off";
      default: return status.toString().split('.').last;
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<BleScanner>();

    return Scaffold(
      appBar: AppBar(title: const Text('Activate')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Center(
              child: Text('Board Scanner',
                  style: Theme.of(context).textTheme.headlineSmall),
            ),
            const SizedBox(height: 16),

            // Status row
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Bluetooth: '),
                Text(
                  _bleLabel(vm.status),
                  style: TextStyle(
                    color: vm.status == BleStatus.ready
                        ? Colors.teal
                        : Colors.redAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Scan / Stop button
            ElevatedButton(
              onPressed: vm.scanning ? vm.stopScan : vm.startScan,
              style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text(vm.scanning ? 'Stop Scan' : 'Start Scan'),
            ),
            const SizedBox(height: 16),

            Text('Found  Devices:', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),

            Expanded(
              child: vm.devices.isEmpty
                  ? const Center(
                      child: Text('No devices found',
                          style: TextStyle(fontStyle: FontStyle.italic)))
                  : ListView.separated(
                      itemCount: vm.devices.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final d = vm.devices[i];
                        final name = (d.name?.isNotEmpty ?? false)
                            ? d.name!
                            : 'Unknown';
                        return ListTile(
                          leading: const Icon(Icons.bluetooth),
                          title: Text(name),
                          subtitle: Text('${d.id}\nRSSI: ${d.rssi ?? 0} dBm'),
                          isThreeLine: true,
                          onTap: () async {
                            // TODO: navigate or return this device to next flow
                              await showActivationSheet(context: context, device: d);

                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
