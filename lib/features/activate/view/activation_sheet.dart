// lib/features/activation/ui/activation_sheet.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import '../../../storage/config_history_store.dart';
import '../../../storage/key_store.dart';
// Update these imports to match your project structure
import '../../../common/widgets/qr_scanner_page.dart';
import '../../../config/api_config.dart';
import '../data/board_ble_service.dart';

class ActivationData {
  // Tab 1 (Activate)
  String sealCode = '';
  String serialNumber = '';

  // Tab 2 (Place)
  String project = '';
  String place = '';
  String baseUrl = '';
  String connectionType = 'wifi'; // Wifi | RS485 | LAN
  String projectName = "";
  // Tab 3 (Connect)
  String deviceId = '';
  String locationName = '';
  bool inputEnable = false;
  bool outputEnable = false;
  bool isConsumer = false; // Optional, not used by device

  // Wi-Fi (used when connectionType == 'Wifi')
  String wifiName = '';
  String wifiPass = '';
}

Future<void> showActivationSheet({
  required BuildContext context,
  required DiscoveredDevice device,
}) async {
  final data = ActivationData()..deviceId = device.id;
  final ble = FlutterReactiveBle();
  final service = BoardBleService(ble);

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    builder: (ctx) => _ActivationSheet(data: data, service: service),
  );

  await service.dispose();
}

class _ActivationSheet extends StatefulWidget {
  final ActivationData data;
  final BoardBleService service;
  const _ActivationSheet({required this.data, required this.service});

  @override
  State<_ActivationSheet> createState() => _ActivationSheetState();
}

class _ActivationSheetState extends State<_ActivationSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  bool _connecting = false;
  bool _sent = false;

  // Activate ctrls
  final _sealCtrl = TextEditingController();
  final _serialCtrl = TextEditingController();

  // Place ctrls
  final _baseUrlCtrl = TextEditingController(); // manual override if needed
  String? _selectedProject;
  String? _selectedLocation;

  // Connect state
  bool _inEnable = false;
  bool _outEnable = false;
  bool _isConsumer = false;
  // Projects: project -> list of locations
  Map<String, List<_LocItem>> _projects = {};
  bool _loadingProjects = false;
  String? _projectsError;

  // Keys state (Config tab)
  String? _pubKeyPem;
  String? _privKeyPem;
  String? _privKeyBase64; // what we send to board
  bool _loadingKeys = false;
  String? _keysError;

  // CFG save/read state
  bool _savingCfg = false;
  String? _savedCfgPath;
  Map<String, dynamic>? _savedCfgReloaded;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _tabs.addListener(() {
      if (_tabs.indexIsChanging) return;
      if (_tabs.index == 1) {
        _fetchProjects();
      } else if (_tabs.index == 3) {
        _collectForm();
        _maybeFetchKeys();
      }
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _sealCtrl.dispose();
    _serialCtrl.dispose();
    _baseUrlCtrl.dispose();
    super.dispose();
  }

  // -------------------- Networking --------------------

  Future<void> _fetchProjects() async {
    if (_loadingProjects) return;
    setState(() {
      _loadingProjects = true;
      _projectsError = null;
    });
    try {
      final res = await http.get(
        ApiConfig.apiUri(ApiConfig.projects),
        headers: await ApiConfig.projectsHeaders(), // ✅ await the map
      );
      if (res.statusCode != 200) {
        if (res.statusCode == 401) {
          throw Exception('Unauthorized: APP-Auth is missing/invalid.');
        }
        throw Exception('HTTP ${res.statusCode}: ${res.body}');
      }
      final decoded = jsonDecode(res.body);
      _projects = _parseProjects(decoded);
      if (_projects.isEmpty) {
        throw Exception('No projects found in response.');
      }
      setState(() {
        _selectedProject ??= _projects.keys.first;
        final locs = _projects[_selectedProject] ?? [];
        _selectedLocation ??= locs.isNotEmpty ? locs.first.name : null;
        final baseFromSel = _findBaseUrl(_selectedProject, _selectedLocation);
        if (baseFromSel != null) _baseUrlCtrl.text = baseFromSel;
      });
    } catch (e) {
      setState(() => _projectsError = '$e');
    } finally {
      if (mounted) setState(() => _loadingProjects = false);
    }
  }

  Future<void> _maybeFetchKeys() async {
    if (_loadingKeys) return;
    if (widget.data.serialNumber.isEmpty) {
      setState(() => _keysError = 'Serial number is empty.');
      return;
    }
    setState(() {
      _loadingKeys = true;
      _keysError = null;
    });
    try {
      final headers = await ApiConfig.jsonHeadersAsync();

      final res = await http.post(
        ApiConfig.apiUri(ApiConfig.rsaKey),
        headers: headers,
        body: jsonEncode({"serial": widget.data.serialNumber}),
      );
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}: ${res.body}');
      }
      final m = jsonDecode(res.body) as Map<String, dynamic>;

      // Flexible key names handling
      String? pub =
          (m['public key'] ?? m['public'] ?? m['publicKey']) as String?;
      String? priv =
          (m['private key'] ?? m['private'] ?? m['privateKey']) as String?;

      pub = pub?.trim() ?? '';
      priv = priv?.trim() ?? '';

      final privB64 = priv ?? '';

      setState(() {
        _pubKeyPem = (pub!.isEmpty) ? null : pub;
        _privKeyPem = (priv!.isEmpty) ? null : priv;
        _privKeyBase64 = (privB64.isEmpty) ? null : privB64;
      });
    } catch (e) {
      setState(() => _keysError = 'Fetch keys failed: $e');
    } finally {
      if (mounted) setState(() => _loadingKeys = false);
    }
  }

  // -------------------- BLE & Send --------------------

  Future<void> _connect() async {
    setState(() => _connecting = true);
    try {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      await widget.service.connect(widget.data.deviceId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Connected to board')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Connect failed: $e')));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _sendConfig() async {
    _collectForm();

    if (_privKeyBase64 == null || _privKeyBase64!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Private key not fetched. Tap "Get RSA Keys".'),
        ),
      );
      return;
    }
    if (widget.data.baseUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'BaseURL is empty. Select project/location or type it.',
          ),
        ),
      );
      return;
    }

    final payload = _buildSendPayload();

    try {

      await ConfigHistoryStore.add(
        deviceId: widget.data.deviceId,
        baseUrl: widget.data.baseUrl,
        payload: payload,
        success: true,
        section: _selectedLocation, // ✅ new
        connectionType: widget.data.connectionType, // ✅ new
        extra: {
          'project': widget.data.projectName,
          'location': widget.data.locationName,
        },
      );

      await widget.service.sendConfig(
        deviceId: widget.data.deviceId,
        payload: payload,
      );
      final serial = (payload['serial_number'] ?? '').toString();
      if (serial.isNotEmpty) {
        await KeyStore.markUsedBySerial(serial);
        // اگر private_key هم از سمت سرور دارید و می‌خواهید در QR کامل ذخیره شود:
        final pk = (payload['private_key'] ?? '').toString();
        if (pk.isNotEmpty) {
          await KeyStore.attachPrivateKeyAndUse(serial, pk);
        }
      }
      if (!mounted) return;
      setState(() => _sent = true);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Configuration sent')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Send failed: $e')));
    }
  }

  Map<String, dynamic> _buildSendPayload() => {
    // EXACT names requested by your firmware:
    "serial_number": widget.data.serialNumber,
    "private_key": _privKeyBase64, // from API (PEM stripped to base64)
    "base_url": widget.data.baseUrl,
    "enabled_input": widget.data.inputEnable,
    "enabled_output": widget.data.outputEnable,
    "connection_type": widget.data.connectionType, // Wifi | RS485 | LAN
    "is_consumer": widget.data.isConsumer, // Optional, not used by device
    "wifi_name": widget.data.wifiName, // only if Wifi
    "wifi_pass": widget.data.wifiPass, // only if Wifi
  };

  // -------------------- CFG Save / Read --------------------

  Map<String, dynamic> _buildCfgJson() => {
    // Minimal cfg mirrors the device payload (plus optional meta)
    "serial_number": widget.data.serialNumber,
    "private_key": _privKeyBase64,
    "base_url": widget.data.baseUrl,
    "enabled_input": widget.data.inputEnable,
    "enabled_output": widget.data.outputEnable,
    "connection_type": widget.data.connectionType,
    "is_consumer": widget.data.isConsumer, // Optional, not used by device
    "meta": {
      "savedAt": DateTime.now().toIso8601String(),
      // Optional context, not used by device:
      "project": widget.data.project,
      "place": widget.data.place,
      "sealCode": widget.data.sealCode,
    },
  };
Future<void> _saveCfgToFile() async {
  _collectForm();

  if (_privKeyBase64 == null || _privKeyBase64!.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Private key is empty. Fetch keys first.')),
    );
    return;
  }

  setState(() {
    _savingCfg = true;
    _savedCfgPath = null;
    _savedCfgReloaded = null;
  });

  // helper: force .cfg extension (no Platform dependency)
  String _forceCfgExt(String path) {
    final lastSep = path.lastIndexOf(RegExp(r'[\/\\]'));
    final lastDot = path.lastIndexOf('.');
    final hasExt = lastDot > lastSep;
    final base = hasExt ? path.substring(0, lastDot) : path;
    return '$base.cfg';
  }

  try {
    // 1) Build pretty JSON (content stays JSON; only extension will be .cfg)
    final pretty = const JsonEncoder.withIndent('  ').convert(_buildCfgJson());

    // 2) Suggested filename (ensure .cfg)
    final base = widget.data.serialNumber.isNotEmpty
        ? 'board_cfg_${widget.data.serialNumber}'
        : 'board_cfg_${DateTime.now().millisecondsSinceEpoch}';
    final suggestedName = base.endsWith('.cfg') ? base : '$base.cfg';

    String? finalPath;

    // 3) Try native “Save as...”
    try {
      final loc = await fs.getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: [fs.XTypeGroup(label: 'CFG', extensions: ['cfg'])],
      );
      if (loc != null) {
        final bytes = Uint8List.fromList(utf8.encode(pretty));
        final xf = fs.XFile.fromData(
          bytes,
          name: suggestedName,
          mimeType: 'text/plain', // content is JSON, extension is .cfg
        );
        final targetPath = _forceCfgExt(loc.path); // ✅ enforce .cfg
        await xf.saveTo(targetPath);
        finalPath = targetPath;
      }
    } catch (_) {
      // Missing plugin / platform not supported → fall back
    }

    // 4) Fallback: save to app documents dir (with .cfg)
    if (finalPath == null) {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$suggestedName');
      await file.writeAsString(pretty, flush: true);
      finalPath = file.path;
    }

    // 5) Verify by read-back (still JSON even if .cfg)
    final txt = await File(finalPath).readAsString();
    final decoded = jsonDecode(txt) as Map<String, dynamic>;

    if (!mounted) return;
    setState(() {
      _savedCfgPath = finalPath;
      _savedCfgReloaded = decoded;
    });

    // 6) Show “Saved” sheet with actions
    if (mounted) {
      await _showSavedSheet(context, finalPath);
    }
  } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Save/read CFG failed: $e')),
    );
  } finally {
    if (mounted) setState(() => _savingCfg = false);
  }
}

Future<void> _showSavedSheet(BuildContext context, String path) async {
  await showModalBottomSheet(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final fileName = path.split(Platform.pathSeparator).last;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 8),
                Text('Config saved', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            Text(fileName, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SelectableText(
              path,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      final res = await OpenFilex.open(path);
                      if (res.type != ResultType.done && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Could not open file (${res.message})')),
                        );
                      }
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: path));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Path copied')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy path'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await Share.shareXFiles(
                          [XFile(path, mimeType: 'application/json')],
                          text: 'Configuration file',
                        );
                      } catch (_) {}
                    },
                    icon: const Icon(Icons.share),
                    label: const Text('Share'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

  // -------------------- UI helpers --------------------

  void _collectForm() {
    widget.data
      ..sealCode = _sealCtrl.text.trim()
      ..serialNumber = _serialCtrl.text.trim()
      ..project = _selectedProject ?? ''
      ..place = _selectedLocation ?? ''
      ..baseUrl = _baseUrlCtrl.text.trim()
      ..inputEnable = _inEnable
      ..outputEnable = _outEnable;
    // connectionType is updated directly in the dropdown's onChanged
  }

  Future<void> _scanTo(TextEditingController controller, String title) async {
    final s = await Permission.camera.request();
    if (!s.isGranted) return;

    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => QrScannerPage(title: title)),
    );
    if (!mounted) return;
    if (code != null && code.isNotEmpty) {
      setState(() => controller.text = code);
    }
  }



  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).viewInsets.bottom + 16;
    return Padding(
      padding: EdgeInsets.only(bottom: pad),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(width: 16),
                Text(
                  'Activate Board',
                  style: Theme.of(context).textTheme.titleLarge!,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TabBar(
              controller: _tabs,
              isScrollable: true,
              tabs: const [
                Tab(text: 'Activate'),
                Tab(text: 'Place'),
                Tab(text: 'Connect'),
                Tab(text: 'Config'),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _tabActivate(),
                  _tabPlace(),
                  _tabConnect(),
                  _tabConfig(),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Close'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () {
                      if (_tabs.index < 3) {
                        _tabs.animateTo(_tabs.index + 1);
                      } else {
                        _sendConfig();
                      }
                    },
                    child: Text(
                      _tabs.index < 3
                          ? 'Continue'
                          : _sent
                          ? 'Sent'
                          : 'Send To Board',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------- Tabs --------------------

  Widget _tabActivate() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _serialCtrl,
          decoration: InputDecoration(
            labelText: 'Serial Number',
            suffixIcon: IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: () => _scanTo(_serialCtrl, 'Scan Serial QR'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _sealCtrl,
          decoration: InputDecoration(
            labelText: 'Seal Code (not sent to device)',
            suffixIcon: IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: () => _scanTo(_sealCtrl, 'Scan Seal QR'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tabPlace() {
    final projects = _projects.keys.toList()..sort();
    final currentLocs = _projects[_selectedProject] ?? const <_LocItem>[];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text('Projects', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loadingProjects ? null : _fetchProjects,
              icon: _loadingProjects
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_projectsError != null) ...[
          const SizedBox(height: 8),
          Text(
            _projectsError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
        ],
        DropdownButtonFormField<String>(
          value: _selectedProject,
          items: projects
              .map((p) => DropdownMenuItem(value: p, child: Text(p)))
              .toList(),
          onChanged: (v) {
            setState(() {
              _selectedProject = v;
              _selectedLocation = null;
              final locs = _projects[_selectedProject] ?? [];
              if (locs.isNotEmpty) _selectedLocation = locs.first.name;
              final base = _findBaseUrl(_selectedProject, _selectedLocation);
              if (base != null) _baseUrlCtrl.text = base;
            });
          },
          decoration: const InputDecoration(labelText: 'Project'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _selectedLocation,
          items: currentLocs
              .map((l) => DropdownMenuItem(value: l.name, child: Text(l.name)))
              .toList(),
          onChanged: (v) {
            setState(() {
              _selectedLocation = v;
              final base = _findBaseUrl(_selectedProject, _selectedLocation);
              if (base != null) _baseUrlCtrl.text = base;
            });
          },
          decoration: const InputDecoration(labelText: 'Location'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _baseUrlCtrl,
          decoration: const InputDecoration(
            labelText: 'BaseURL (auto from selection, editable)',
          ),
        ),
      ],
    );
  }

  Widget _tabConnect() {
    final isWifi = widget.data.connectionType == 'wifi';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          leading: const Icon(Icons.bluetooth),
          title: const Text('Selected device'),
          subtitle: Text(widget.data.deviceId),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: _connecting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link),
          label: Text(_connecting ? 'Connecting...' : 'Connect'),
          onPressed: _connecting ? null : _connect,
        ),
        const Divider(height: 32),

        // Connection type
        DropdownButtonFormField<String>(
          value: widget.data.connectionType,
          items: const [
            DropdownMenuItem(value: 'wifi', child: Text('wifi')),
            DropdownMenuItem(value: 'rs485', child: Text('rs485')),
            DropdownMenuItem(value: 'lan', child: Text('lan')),
          ],
          onChanged: (v) => setState(() {
            widget.data.connectionType = v ?? 'Wifi';
          }),
          decoration: const InputDecoration(labelText: 'Connection Type'),
        ),

        // Wi-Fi fields (only when Wifi)
        if (isWifi) ...[
          const SizedBox(height: 12),
          TextFormField(
            initialValue: widget.data.wifiName,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Wi-Fi Name (SSID)',
              hintText: 'e.g. OfficeWifi',
            ),
            onChanged: (v) => setState(() => widget.data.wifiName = v.trim()),
          ),
          const SizedBox(height: 12),
          StatefulBuilder(
            builder: (context, setLocal) {
              // local state to show/hide password without touching parent state
              bool show = false;
              return TextFormField(
                initialValue: widget.data.wifiPass,
                obscureText: !show,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Wi-Fi Password',
                  suffixIcon: StatefulBuilder(
                    builder: (context, setIcon) => IconButton(
                      tooltip: show ? 'Hide' : 'Show',
                      icon: Icon(
                        show ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () {
                        show = !show;
                        // rebuild both text field and icon
                        setLocal(() {});
                        setIcon(() {});
                      },
                    ),
                  ),
                ),
                onChanged: (v) => setState(() => widget.data.wifiPass = v),
              );
            },
          ),
        ],

        const SizedBox(height: 12),
        SwitchListTile(
          value: widget.data.inputEnable,
          onChanged: (v) => setState(() => widget.data.inputEnable = v),
          title: const Text('Input Enable'),
        ),
        SwitchListTile(
          value: widget.data.outputEnable,
          onChanged: (v) => setState(() => widget.data.outputEnable = v),
          title: const Text('Output Enable'),
        ),
        SwitchListTile(
          value: widget.data.isConsumer,
          onChanged: (v) => setState(() => widget.data.isConsumer = v),
          title: const Text('Consumer device'),
          subtitle: const Text('Send is_consumer flag in configuration'),
        ),
      ],
    );
  }

  Widget _tabConfig() {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall;

    // Build a sanitized preview (don’t show the full private key)
    Map<String, dynamic> preview = {
      "BaseURL": _baseUrlCtrl.text,
      "PrivetKeyBase64": _privKeyBase64 == null
          ? null
          : "*** (${_privKeyBase64!.length} chars)",
      "SerialNumber": _serialCtrl.text,
      "InputEnable": _inEnable,
      "OutputEnable": _outEnable,
      "ConnectionType": widget.data.connectionType,
      "isConsumer": _isConsumer,
    };

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Summary', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _kv('Project', _selectedProject ?? '—'),
        _kv('Location', _selectedLocation ?? '—'),
        _kv('BaseURL', _baseUrlCtrl.text),
        _kv('SerialNumber', _serialCtrl.text),
        _kv('SealCode', _sealCtrl.text),
        _kv('InputEnable', _inEnable.toString()),
        _kv('OutputEnable', _outEnable.toString()),
        _kv('ConnectionType', widget.data.connectionType),
        _kv('is consumber', _isConsumer.toString()),
        const SizedBox(height: 12),

        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _loadingKeys ? null : _maybeFetchKeys,
              icon: _loadingKeys
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.key),
              label: Text(_loadingKeys ? 'Fetching...' : 'Get RSA Keys'),
            ),
            if (_privKeyBase64 != null)
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _privKeyBase64!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Private key (base64) copied'),
                    ),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy Private (base64)'),
              ),
            FilledButton.icon(
              onPressed: _savingCfg ? null : _saveCfgToFile,
              icon: _savingCfg
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_alt),
              label: Text(_savingCfg ? 'Saving...' : 'Save & Read CFG'),
            ),
          ],
        ),

        if (_keysError != null) ...[
          const SizedBox(height: 8),
          Text(_keysError!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 16),

        if (_pubKeyPem != null || _privKeyPem != null)
          Text('Keys from API', style: theme.textTheme.titleMedium),
        if (_pubKeyPem != null) ...[
          const SizedBox(height: 8),
          Text('Public Key (PEM)', style: theme.textTheme.labelLarge),
          SelectableText(_pubKeyPem!, style: mono),
        ],
        if (_privKeyPem != null) ...[
          const SizedBox(height: 12),
          Text('Private Key (PEM)', style: theme.textTheme.labelLarge),
          SelectableText(_privKeyPem!, style: mono),
        ],
        if (_privKeyBase64 != null) ...[
          const SizedBox(height: 12),
          Text(
            'Private Key (base64, no headers)',
            style: theme.textTheme.labelLarge,
          ),
          SelectableText(_privKeyBase64!, style: mono),
        ],

        if (_savedCfgPath != null) ...[
          const SizedBox(height: 16),
          Text('Saved CFG Path', style: theme.textTheme.titleMedium),
          SelectableText(_savedCfgPath!, style: mono),
        ],
        if (_savedCfgReloaded != null) ...[
          const SizedBox(height: 12),
          Text('Reloaded CFG Preview', style: theme.textTheme.titleMedium),
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(_savedCfgReloaded),
            style: mono,
          ),
        ],

        const SizedBox(height: 16),
        Text('Preview payload to board:', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        SelectableText(
          const JsonEncoder.withIndent('  ').convert(preview),
          style: mono,
        ),
      ],
    );
  }

  // -------------------- Parsing helpers --------------------

  Map<String, List<_LocItem>> _parseProjects(dynamic decoded) {
    final out = <String, List<_LocItem>>{};
    if (decoded is! Map) return out;

    // Accept both: { projects: {...} } or just {...}
    final Map projects = decoded['projects'] is Map
        ? decoded['projects'] as Map
        : decoded;

    for (final entry in projects.entries) {
      final pName = entry.key.toString();
      final pVal = entry.value;
      final locs = <_LocItem>[];

      if (pVal is Map) {
        // Case 4: baseUrlKey -> List<location>
        // e.g.
        // "Sharif University": {
        //   "123.213.452.1:8080": ["loc1","loc2",...]
        // }
        for (final e in pVal.entries) {
          final baseUrlKey = e.key.toString();
          final v = e.value;
          if (v is List) {
            final url = baseUrlKey;
            if (url != null) {
              for (final l in v) {
                final locName = l?.toString() ?? 'Location';
                locs.add(_LocItem(name: locName, baseUrl: url));
              }
            }
          }
        }

        // Case 1: BaseURL block -> { locName: url }
        if (locs.isEmpty) {
          final baseUrlBlock =
              pVal['BaseURL'] ?? pVal['baseUrl'] ?? pVal['baseURL'];
          if (baseUrlBlock is Map) {
            for (final e in baseUrlBlock.entries) {
              final locName = e.key.toString();
              final url = e.value?.toString() ;
              if (url != null) {
                locs.add(_LocItem(name: locName, baseUrl: url));
              }
            }
          }
        }

        // Case 2: direct location -> url pairs
        if (locs.isEmpty) {
          for (final e in pVal.entries) {
            final k = e.key.toString();
            final v = e.value;
            if (v is String) {
              final url = v;
              if (url != null) {
                locs.add(_LocItem(name: k, baseUrl: url));
              }
            }
          }
        }

        // Case 3: one baseUrl + locations list
        if (locs.isEmpty) {
          final singleBase =
              pVal['BaseURL'] ?? pVal['baseUrl'] ?? pVal['baseURL'];
          final locations = pVal['Locations'] ?? pVal['locations'];
          final url = singleBase?.toString() ;
          if (url != null) {
            if (locations is List) {
              for (final l in locations) {
                final locName = l?.toString() ?? 'Location';
                locs.add(_LocItem(name: locName, baseUrl: url));
              }
            } else {
              locs.add(_LocItem(name: 'Default', baseUrl: url));
            }
          }
        }
      }

      if (locs.isNotEmpty) {
        out[pName] = locs;
      }
    }

    return out;
  }



  bool _looksLikeUrl(String s) =>
      s.startsWith('http://') || s.startsWith('https://');

String? _findBaseUrl(String? project, String? location) {
  if (project == null || location == null) return null;
  final locs = _projects[project] ?? [];

  for (final l in locs) {
    if (l.name == location) {
      final raw = l.baseUrl?.toString().trim();
      if (raw == null || raw.isEmpty) return null;

      // remove http(s):// at start, keep everything else
      var cleaned = raw.replaceFirst(
        RegExp(r'^\s*https?:\/\/', caseSensitive: false),
        '',
      );

      // optional: also remove trailing slashes for consistency
      cleaned = cleaned.replaceFirst(RegExp(r'/+$'), '');

      return cleaned;
    }
  }
  return null;
}


  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 160, child: Text('$k:')),
          Expanded(child: SelectableText(v.isEmpty ? '—' : v)),
        ],
      ),
    );
  }
}

class _LocItem {
  final String name;
  final String baseUrl;
  const _LocItem({required this.name, required this.baseUrl});
}
