// lib/features/activation/ui/activation_sheet.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

// Update these imports to match your project structure
import '../../../common/widgets/qr_scanner_page.dart';
import '../../../config/api_config.dart';
import '../data/board_ble_service.dart';

class ActivationData {
  // Tab 1 (Activate)
  String sealCode = '';
  String serialNumber = ''; // also used as "activate.key"

  // Tab 2 (Place)
  String project = '';
  String place = '';
  String baseUrl = '';

  // Tab 3 (Connect)
  String deviceId = '';
  bool inputEnable = false;
  bool outputEnable = false;
  String boardRole = 'consumer'; // consumer | producer
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
  String _role = 'consumer';

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
      final res = await http.post(
        ApiConfig.apiUri(ApiConfig.projects),
        headers: ApiConfig.projectsHeaders(),
        body: jsonEncode({}), // may be empty per spec
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
      final res = await http.post(
        ApiConfig.apiUri(ApiConfig.rsaKey),
        headers: ApiConfig.jsonHeaders(),
        body: jsonEncode({"serial": widget.data.serialNumber}),
      );
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}: ${res.body}');
      }
      final m = jsonDecode(res.body) as Map<String, dynamic>;

      // Flexible key names handling
      String? pub = (m['public key'] ?? m['public'] ?? m['publicKey']) as String?;
      String? priv =
          (m['private key'] ?? m['private'] ?? m['privateKey']) as String?;

      pub = pub?.trim() ?? '';
      priv = priv?.trim() ?? '';

      final privB64 = _pemToBase64(priv ?? '');

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connected to board')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connect failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _sendConfig() async {
    _collectForm();

    if (_privKeyBase64 == null || _privKeyBase64!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Private key not fetched. Tap "Get RSA Keys".')),
      );
      return;
    }
    if (widget.data.baseUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('BaseURL is empty. Select project/location or type it.')),
      );
      return;
    }

    final payload = _buildSendPayload();

    try {
      await widget.service.sendConfig(
        deviceId: widget.data.deviceId,
        payload: payload,
      );
      if (!mounted) return;
      setState(() => _sent = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuration sent')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Send failed: $e')),
      );
    }
  }

  Map<String, dynamic> _buildSendPayload() => {
        "type": "config",
        "activate": {
          "key": widget.data.serialNumber, // key == serial
          "sealCode": widget.data.sealCode,
        },
        "place": {
          "project": widget.data.project,
          "location": widget.data.place,
        },
        "connect": {
          "deviceId": widget.data.deviceId,
        },
        "config": {
          "baseUrl": widget.data.baseUrl,
          "privateKeyBase64": _privKeyBase64, // from API, no PEM headers
          "serialNumber": widget.data.serialNumber,
          "inputEnable": widget.data.inputEnable,
          "outputEnable": widget.data.outputEnable,
          "boardRole": widget.data.boardRole, // consumer | producer
        }
      };

  // -------------------- CFG Save / Read --------------------

  Map<String, dynamic> _buildCfgJson() => {
        // Save a richer file (can be used later to restore UI or re-send)
        "activate": {
          "key": widget.data.serialNumber,
          "sealCode": widget.data.sealCode,
        },
        "place": {
          "project": widget.data.project,
          "location": widget.data.place,
        },
        "connect": {"deviceId": widget.data.deviceId},
        "config": {
          "baseUrl": widget.data.baseUrl,
          "privateKeyBase64": _privKeyBase64,
          "serialNumber": widget.data.serialNumber,
          "inputEnable": widget.data.inputEnable,
          "outputEnable": widget.data.outputEnable,
          "boardRole": widget.data.boardRole,
        },
        // Optional: keep PEMs for audit/backup
        "keys": {
          if (_pubKeyPem != null) "publicPem": _pubKeyPem,
          if (_privKeyPem != null) "privatePem": _privKeyPem,
        },
        "meta": {
          "savedAt": DateTime.now().toIso8601String(),
          "app": "YourAppName",
        }
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

    try {
      final dir = await getApplicationDocumentsDirectory();
      final name = (widget.data.serialNumber.isNotEmpty)
          ? 'board_cfg_${widget.data.serialNumber}.json'
          : 'board_cfg_${DateTime.now().millisecondsSinceEpoch}.json';
      final file = File('${dir.path}/$name');

      final pretty = const JsonEncoder.withIndent('  ').convert(_buildCfgJson());
      await file.writeAsString(pretty, flush: true);

      // Read-back to verify
      final txt = await file.readAsString();
      final decoded = jsonDecode(txt) as Map<String, dynamic>;

      if (!mounted) return;
      setState(() {
        _savedCfgPath = file.path;
        _savedCfgReloaded = decoded;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CFG saved & reloaded ✓\n${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save/read CFG failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _savingCfg = false);
    }
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
      ..outputEnable = _outEnable
      ..boardRole = _role;
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

  String _pemToBase64(String pem) {
    final lines = pem
        .replaceAll('\r', '')
        .split('\n')
        .where((l) => !l.startsWith('-----') && l.trim().isNotEmpty)
        .toList();
    return lines.join('');
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
                Text('Activate Board', style: Theme.of(context).textTheme.titleLarge),
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
                    child: Text(_tabs.index < 3
                        ? 'Continue'
                        : _sent ? 'Sent' : 'Send To Board'),
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
            labelText: 'Serial Number (also used as Key)',
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
            labelText: 'Seal Code',
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
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
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
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.link),
          label: Text(_connecting ? 'Connecting...' : 'Connect'),
          onPressed: _connecting ? null : _connect,
        ),
        const Divider(height: 32),
        DropdownButtonFormField<String>(
          value: _role,
          items: const [
            DropdownMenuItem(value: 'consumer', child: Text('Consumer')),
            DropdownMenuItem(value: 'producer', child: Text('Producer')),
          ],
          onChanged: (v) => setState(() => _role = v ?? 'consumer'),
          decoration: const InputDecoration(labelText: 'Board Role'),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          value: _inEnable,
          onChanged: (v) => setState(() => _inEnable = v),
          title: const Text('Input Enable'),
        ),
        SwitchListTile(
          value: _outEnable,
          onChanged: (v) => setState(() => _outEnable = v),
          title: const Text('Output Enable'),
        ),
      ],
    );
  }

  Widget _tabConfig() {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Summary', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _kv('Project', _selectedProject ?? '—'),
        _kv('Location', _selectedLocation ?? '—'),
        _kv('BaseURL', _baseUrlCtrl.text),
        _kv('SerialNumber / Key', _serialCtrl.text),
        _kv('SealCode', _sealCtrl.text),
        _kv('Role', _role),
        _kv('InputEnable', _inEnable.toString()),
        _kv('OutputEnable', _outEnable.toString()),
        const SizedBox(height: 12),

        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _loadingKeys ? null : _maybeFetchKeys,
              icon: _loadingKeys
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.key),
              label: Text(_loadingKeys ? 'Fetching...' : 'Get RSA Keys'),
            ),
            if (_privKeyBase64 != null)
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _privKeyBase64!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Private key (base64) copied')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy Private (base64)'),
              ),
            FilledButton.icon(
              onPressed: _savingCfg ? null : _saveCfgToFile,
              icon: _savingCfg
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
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
          Text('Private Key (base64, no headers)', style: theme.textTheme.labelLarge),
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
          const JsonEncoder.withIndent('  ').convert({
            "type": "config",
            "activate": {"key": "<serialNumber>", "sealCode": "<sealCode>"},
            "place": {"project": "<project>", "location": "<location>"},
            "connect": {"deviceId": "<deviceId>"},
            "config": {
              "baseUrl": "<baseUrl>",
              "privateKeyBase64": "***",
              "serialNumber": "<serialNumber>",
              "inputEnable": false,
              "outputEnable": false,
              "boardRole": "consumer",
            }
          }),
          style: mono,
        ),
      ],
    );
  }

  // -------------------- Parsing helpers --------------------

  Map<String, List<_LocItem>> _parseProjects(dynamic decoded) {
    final out = <String, List<_LocItem>>{};
    if (decoded is! Map) return out;
    final projects = decoded['projects'];
    if (projects is! Map) return out;

    for (final entry in projects.entries) {
      final pName = entry.key.toString();
      final pVal = entry.value;

      final locs = <_LocItem>[];

      if (pVal is Map) {
        // Case 1: BaseURL map
        final baseUrlBlock = pVal['BaseURL'] ?? pVal['baseUrl'] ?? pVal['baseURL'];
        if (baseUrlBlock is Map) {
          for (final e in baseUrlBlock.entries) {
            final locName = e.key.toString();
            final url = e.value?.toString() ?? '';
            if (_looksLikeUrl(url)) {
              locs.add(_LocItem(name: locName, baseUrl: url));
            }
          }
        }

        // Case 2: direct location->url pairs
        if (locs.isEmpty) {
          for (final e in pVal.entries) {
            final k = e.key.toString();
            final v = e.value;
            if (v is String && _looksLikeUrl(v)) {
              locs.add(_LocItem(name: k, baseUrl: v));
            }
          }
        }

        // Case 3: one baseUrl + locations list
        if (locs.isEmpty) {
          final singleBase = pVal['BaseURL'] ?? pVal['baseUrl'] ?? pVal['baseURL'];
          final locations = pVal['Locations'] ?? pVal['locations'];
          if (singleBase is String && _looksLikeUrl(singleBase)) {
            if (locations is List) {
              for (final l in locations) {
                final locName = l?.toString() ?? 'Location';
                locs.add(_LocItem(name: locName, baseUrl: singleBase));
              }
            } else {
              locs.add(_LocItem(name: 'Default', baseUrl: singleBase));
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

  bool _looksLikeUrl(String s) => s.startsWith('http://') || s.startsWith('https://');

  String? _findBaseUrl(String? project, String? location) {
    if (project == null || location == null) return null;
    final locs = _projects[project] ?? [];
    for (final l in locs) {
      if (l.name == location) return l.baseUrl;
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
