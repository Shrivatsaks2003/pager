import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/pager_device.dart';
import 'add_pager_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pagerBox = Hive.box<PagerDevice>('pagers');

    return Scaffold(
      appBar: AppBar(
        title: const Text("Pager Settings"),
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
                            pager.isAssigned
                                ? Icons.lock
                                : Icons.lock_open,
                            size: 16,
                            color: pager.isAssigned
                                ? Colors.red
                                : Colors.green,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            pager.isAssigned
                                ? "Assigned"
                                : "Available",
                            style: TextStyle(
                              color: pager.isAssigned
                                  ? Colors.red
                                  : Colors.green,
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
                        : () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text("Delete Pager"),
                                content: Text(
                                  "Delete Pager ${pager.pagerNumber}?",
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(dialogContext, false),
                                    child: const Text("Cancel"),
                                  ),
                                  ElevatedButton(
                                    onPressed: () =>
                                        Navigator.pop(dialogContext, true),
                                    child: const Text("Delete"),
                                  ),
                                ],
                              ),
                            );

                            if (confirm == true) {
                              pager.delete();
                            }
                          },
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
