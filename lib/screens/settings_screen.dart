import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/pager_device.dart';
import '../services/app_config_service.dart';
import '../services/ble_service.dart';
import '../services/auth_service.dart';
import 'add_pager_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  final _masterNameController = TextEditingController();
  final _masterMacController = TextEditingController();
  bool _syncing = false;
  bool _savingMasterMac = false;
  bool _renamingMaster = false;
  List<MasterPagerCsvRow> _lastReportRows = const [];
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _masterNameController.text = AppConfigService.instance.masterBleName;
    _masterMacController.text =
        AppConfigService.instance.masterMacAddress ?? '';
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _masterNameController.dispose();
    _masterMacController.dispose();
    super.dispose();
  }

  Future<void> _scanMasterMac() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _MacScannerPage()),
    );
    if (result == null || !mounted) return;

    final normalized = AppConfigService.instance.normalizeMacAddress(result);
    if (normalized == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scanned value does not contain a valid MAC address.'),
        ),
      );
      return;
    }

    setState(() {
      _masterMacController.text = normalized;
    });
  }

  Future<void> _saveMasterMac() async {
    final normalized = AppConfigService.instance.normalizeMacAddress(
      _masterMacController.text,
    );
    if (normalized == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter or scan a full MAC address like AA:BB:CC:DD:EE:FF.',
          ),
        ),
      );
      return;
    }

    setState(() => _savingMasterMac = true);
    await AppConfigService.instance.saveMasterMacAddress(normalized);
    if (!mounted) return;
    setState(() {
      _savingMasterMac = false;
      _masterMacController.text = normalized;
    });

    final derivedCode = AppConfigService.instance.extractAuthCodeFromMac(
      normalized,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Master MAC saved. The app will use ${derivedCode ?? 'the last 4 digits'} automatically when connecting.',
        ),
      ),
    );
  }

  Future<void> _renameConnectedMaster() async {
    final newName = _masterNameController.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Master BLE name cannot be empty.')),
      );
      return;
    }

    if (!BleService.instance.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connect to the current master before renaming it.'),
        ),
      );
      return;
    }

    setState(() => _renamingMaster = true);
    final response = await BleService.instance.renameConnectedMaster(newName);
    if (!mounted) return;
    setState(() => _renamingMaster = false);

    if (response == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No response from master.')));
      return;
    }

    if (!response.startsWith('OK:')) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(response)));
      return;
    }

    await AppConfigService.instance.saveMasterBleName(newName);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$response The master will restart advertising with the new name.',
        ),
      ),
    );
    setState(() {});
  }

  Widget _buildMasterSecurityCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Master Security',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Scan or enter the full master MAC address once. The app will extract the last 4 hex digits and send them automatically every time it connects.',
              style: TextStyle(color: colors.onSurfaceVariant, height: 1.35),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _masterMacController,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Master MAC address',
                hintText: 'Example: AA:BB:CC:DD:EE:FF',
                prefixIcon: Icon(Icons.memory_rounded),
                helperText:
                    'Colons, lowercase text, pasted values, and scanned text are handled automatically.',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _scanMasterMac,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('Scan MAC'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _savingMasterMac ? null : _saveMasterMac,
                    child: Text(_savingMasterMac ? 'Saving...' : 'Save MAC'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _masterNameController,
              decoration: InputDecoration(
                labelText: 'Master BLE name',
                hintText: AppConfigService.defaultMasterName,
                prefixIcon: const Icon(Icons.bluetooth_searching_rounded),
                helperText:
                    'Default is ${AppConfigService.defaultMasterName}. Rename while connected to update the master device itself.',
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _renamingMaster ? null : _renameConnectedMaster,
                child: Text(
                  _renamingMaster ? 'Updating...' : 'Rename Connected Master',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _syncFromMaster() async {
    if (_syncing) return;

    if (!BleService.instance.isConnected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Connect to master first")));
      return;
    }

    setState(() => _syncing = true);
    final result = await BleService.instance.fetchMasterRows();
    if (!mounted) return;
    setState(() => _syncing = false);

    if (!result.isSuccess || result.rows == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? "Failed to fetch report")),
      );
      return;
    }

    final allRows = result.rows!;
    final rows = allRows.where((row) => row.active).toList();
    final pagerBox = Hive.box<PagerDevice>('pagers');
    int changed = 0;
    int removed = 0;
    int skippedAssigned = 0;

    for (final row in rows) {
      PagerDevice? existing;
      for (final pager in pagerBox.values) {
        if (pager.macAddress.toUpperCase() == row.mac) {
          existing = pager;
          break;
        }
      }

      if (existing == null) {
        await pagerBox.add(
          PagerDevice(
            macAddress: row.mac,
            pagerNumber: row.pagerNumber,
            isAssigned: false,
          ),
        );
        changed++;
        continue;
      }

      if (existing.pagerNumber != row.pagerNumber) {
        existing.pagerNumber = row.pagerNumber;
        await existing.save();
        changed++;
      }
    }

    final masterMacs = rows.map((r) => r.mac.toUpperCase()).toSet();
    final localPagers = pagerBox.values.toList();
    for (final pager in localPagers) {
      final mac = pager.macAddress.toUpperCase();
      if (masterMacs.contains(mac)) continue;
      if (pager.isAssigned) {
        skippedAssigned++;
        continue;
      }
      await pager.delete();
      removed++;
    }

    if (!mounted) return;
    setState(() {
      _lastReportRows = rows;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "Sync complete: ${rows.length} active rows, $changed updates, $removed removed, $skippedAssigned kept (assigned)",
        ),
      ),
    );
  }

  Future<void> _deletePager(PagerDevice pager) async {
    if (pager.isAssigned) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Delete Pager"),
        content: Text("Delete Pager ${pager.pagerNumber} from master and app?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    if (!BleService.instance.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Connect to master to delete pager")),
      );
      return;
    }

    final response = await BleService.instance.deletePager(pager.pagerNumber);
    if (!mounted) return;

    if (response == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("No response from master")));
      return;
    }

    if (!response.startsWith("OK:")) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(response)));
      return;
    }

    await pager.delete();
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(response)));
  }

  void _showReportSheet() {
    if (_lastReportRows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No report loaded yet. Tap Sync first.")),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Master CSV Report",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                "Rows: ${_lastReportRows.length}",
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: _lastReportRows.length,
                  itemBuilder: (context, index) {
                    final row = _lastReportRows[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        title: Text("Pager ${row.pagerNumber} [${row.serial}]"),
                        subtitle: Text(
                          "MAC: ${row.mac}\n"
                          "Active: ${row.active ? "YES" : "NO"}\n"
                          "LastCmd: ${row.lastCommand}\n"
                          "LastACK: ${row.lastAck} @ ${row.lastAckTime}",
                        ),
                        isThreeLine: true,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyPagersState(ColorScheme colors) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(22),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_off_outlined, size: 36),
          SizedBox(height: 10),
          Text("No pagers registered", style: TextStyle(fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildPagerManagementTab(
    BuildContext context,
    List<PagerDevice> pagers,
    ColorScheme colors,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 100),
      children: [
        if (pagers.isEmpty) _buildEmptyPagersState(colors),
        for (final pager in pagers)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              title: Text(
                "Pager ${pager.pagerNumber}",
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text("MAC: ${pager.macAddress}"),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        pager.isAssigned ? Icons.lock : Icons.lock_open,
                        size: 16,
                        color: pager.isAssigned ? colors.error : Colors.green,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        pager.isAssigned ? "Assigned" : "Available",
                        style: TextStyle(
                          color: pager.isAssigned ? colors.error : Colors.green,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: pager.isAssigned ? null : () => _deletePager(pager),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMasterSecurityTab(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 100),
      children: [_buildMasterSecurityCard(context)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pagerBox = Hive.box<PagerDevice>('pagers');
    final colors = Theme.of(context).colorScheme;
    final isPagerTab = _tabController.index == 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Pager Settings"),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: "Registered Pagers", icon: Icon(Icons.dns_rounded)),
            Tab(
              text: "Master Security",
              icon: Icon(Icons.admin_panel_settings),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: "Log out",
            onPressed: () async {
              await AuthService.instance.signOut();
            },
            icon: const Icon(Icons.logout_rounded),
          ),
          if (isPagerTab) ...[
            IconButton(
              tooltip: "Show last CSV report",
              onPressed: _showReportSheet,
              icon: const Icon(Icons.table_chart),
            ),
            IconButton(
              tooltip: "Sync from master CSV",
              onPressed: _syncing ? null : _syncFromMaster,
              icon: _syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
            ),
          ],
        ],
      ),
      body: ValueListenableBuilder(
        valueListenable: pagerBox.listenable(),
        builder: (context, Box<PagerDevice> box, _) {
          final pagers = box.values.toList()
            ..sort((a, b) => a.pagerNumber.compareTo(b.pagerNumber));

          return TabBarView(
            controller: _tabController,
            children: [
              _buildPagerManagementTab(context, pagers, colors),
              _buildMasterSecurityTab(context),
            ],
          );
        },
      ),
      floatingActionButton: isPagerTab
          ? FloatingActionButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AddPagerScreen()),
                );
              },
              child: const Icon(Icons.add_rounded),
            )
          : null,
    );
  }
}

class _MacScannerPage extends StatefulWidget {
  const _MacScannerPage();

  @override
  State<_MacScannerPage> createState() => _MacScannerPageState();
}

class _MacScannerPageState extends State<_MacScannerPage> {
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  bool scanned = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            fit: BoxFit.cover,
            scanWindow: Rect.fromCenter(
              center: Offset(
                MediaQuery.of(context).size.width / 2,
                MediaQuery.of(context).size.height / 2,
              ),
              width: 260,
              height: 260,
            ),
            onDetect: (capture) async {
              if (scanned) return;

              final barcode = capture.barcodes.first.rawValue;
              if (barcode == null) return;

              scanned = true;
              final navigator = Navigator.of(context);
              await controller.stop();

              if (!mounted) return;
              navigator.pop(barcode);
            },
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _MacScannerOverlayPainter()),
            ),
          ),
          Positioned(
            top: 50,
            left: 20,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () async {
                final navigator = Navigator.of(context);
                await controller.stop();
                if (!mounted) return;
                navigator.pop();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MacScannerOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.85);

    final path = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final cutout = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: 260,
      height: 260,
    );

    path.addRRect(RRect.fromRectAndRadius(cutout, const Radius.circular(20)));
    path.fillType = PathFillType.evenOdd;

    canvas.drawPath(path, paint);

    final borderPaint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    canvas.drawRRect(
      RRect.fromRectAndRadius(cutout, const Radius.circular(20)),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
