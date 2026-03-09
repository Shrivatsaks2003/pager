import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/pager_device.dart';
import '../services/ble_service.dart';
import 'add_pager_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _syncing = false;
  List<MasterPagerCsvRow> _lastReportRows = const [];

  Future<void> _syncFromMaster() async {
    if (_syncing) return;

    if (!BleService.instance.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Connect to master first")),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No response from master")),
      );
      return;
    }

    if (!response.startsWith("OK:")) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(response)),
      );
      return;
    }

    await pager.delete();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(response)),
    );
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

  @override
  Widget build(BuildContext context) {
    final pagerBox = Hive.box<PagerDevice>('pagers');

    return Scaffold(
      appBar: AppBar(
        title: const Text("Pager Settings"),
        actions: [
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
      ),
      body: ValueListenableBuilder(
        valueListenable: pagerBox.listenable(),
        builder: (context, Box<PagerDevice> box, _) {
          final pagers = box.values.toList()
            ..sort((a, b) => a.pagerNumber.compareTo(b.pagerNumber));

          if (pagers.isEmpty) {
            return const Center(
              child: Text(
                "No pagers registered",
                style: TextStyle(fontSize: 16),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: pagers.length,
            itemBuilder: (context, index) {
              final pager = pagers[index];

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Text(
                    "Pager ${pager.pagerNumber}",
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
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
                            color: pager.isAssigned ? Colors.red : Colors.green,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            pager.isAssigned ? "Assigned" : "Available",
                            style: TextStyle(
                              color:
                                  pager.isAssigned ? Colors.red : Colors.green,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: pager.isAssigned
                        ? null
                        : () => _deletePager(pager),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const AddPagerScreen(),
            ),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
