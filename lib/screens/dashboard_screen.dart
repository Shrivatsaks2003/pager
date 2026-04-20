import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/active_session.dart';
import '../models/pager_device.dart';
import '../widgets/session_card.dart';
import '../services/ble_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _connecting = false;
  StreamSubscription<bool>? _bleConnectionSub;

  @override
  void initState() {
    super.initState();
    _bleConnectionSub = BleService.instance.connectionStream.listen((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _bleConnectionSub?.cancel();
    super.dispose();
  }

  // ================= CONNECT / DISCONNECT =================

  Future<void> _connectToMaster() async {
    if (_connecting) return;

    setState(() => _connecting = true);

    if (!BleService.instance.isConnected) {
      bool ok = await BleService.instance.connect();

      if (!mounted) return;

      setState(() {
        _connecting = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? "Connected to master"
                : (BleService.instance.lastError ?? "Master not found"),
          ),
        ),
      );
    } else {
      await BleService.instance.disconnect();

      if (!mounted) return;

      setState(() {
        _connecting = false;
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Disconnected")));
    }
  }

  // ================= ASSIGN DIALOG =================

  void _openAssignDialog() {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final orderController = TextEditingController();

    final pagerBox = Hive.box<PagerDevice>('pagers');
    final sessionBox = Hive.box<ActiveSession>('sessions');

    int? selectedPagerNumber;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final availablePagers = pagerBox.values
                .where((p) => !p.isAssigned)
                .toList();

            return SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 20,
                  bottom: MediaQuery.of(context).viewInsets.bottom + 20,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 48,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      "Assign Pager",
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 20),

                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: "Customer Name",
                        prefixIcon: Icon(Icons.person_outline_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: phoneController,
                      decoration: const InputDecoration(
                        labelText: "Phone Number",
                        prefixIcon: Icon(Icons.call_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: orderController,
                      decoration: const InputDecoration(
                        labelText: "Order ID",
                        prefixIcon: Icon(Icons.receipt_long_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),

                    DropdownButtonFormField<int>(
                      decoration: const InputDecoration(
                        labelText: "Select Pager",
                        prefixIcon: Icon(Icons.notifications_active_outlined),
                      ),
                      initialValue: selectedPagerNumber,
                      items: availablePagers
                          .map(
                            (pager) => DropdownMenuItem<int>(
                              value: pager.pagerNumber,
                              child: Text("Pager ${pager.pagerNumber}"),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        setModalState(() {
                          selectedPagerNumber = value;
                        });
                      },
                    ),
                    const SizedBox(height: 20),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          if (nameController.text.isEmpty ||
                              phoneController.text.isEmpty ||
                              orderController.text.isEmpty ||
                              selectedPagerNumber == null) {
                            return;
                          }

                          final selectedPager = pagerBox.values.firstWhere(
                            (p) => p.pagerNumber == selectedPagerNumber,
                          );

                          selectedPager.isAssigned = true;
                          selectedPager.save();

                          final session = ActiveSession(
                            orderId: orderController.text,
                            customerName: nameController.text,
                            phoneNumber: phoneController.text,
                            pagerNumber: selectedPagerNumber!,
                            createdAt: DateTime.now(),
                          );

                          sessionBox.add(session);

                          Navigator.pop(context);
                        },
                        child: const Text("Assign Pager"),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ================= DELETE SESSION =================

  void _deleteSession(ActiveSession session) {
    final pagerBox = Hive.box<PagerDevice>('pagers');

    final pager = pagerBox.values.firstWhere(
      (p) => p.pagerNumber == session.pagerNumber,
    );

    pager.isAssigned = false;
    pager.save();

    session.delete();
  }

  Future<void> _sendAlertForSession(ActiveSession session) async {
    if (!BleService.instance.isConnected) {
      return;
    }

    final pagerBox = Hive.box<PagerDevice>('pagers');

    final pager = pagerBox.values.firstWhere(
      (p) => p.pagerNumber == session.pagerNumber,
    );

    await BleService.instance.send(pager.macAddress);
  }

  Future<void> _sendPreparingActionForSession(
    ActiveSession session,
    String actionCode,
  ) async {
    if (!BleService.instance.isConnected) {
      return;
    }

    final pagerBox = Hive.box<PagerDevice>('pagers');
    final pager = pagerBox.values.firstWhere(
      (p) => p.pagerNumber == session.pagerNumber,
    );

    // Send by MAC to avoid pager-number mismatch between app and master.
    final command = "STATUS:${pager.macAddress}:${actionCode.toUpperCase()}";
    await BleService.instance.send(command);
  }

  // ================= BUILD =================

  @override
  Widget build(BuildContext context) {
    final sessionBox = Hive.box<ActiveSession>('sessions');
    final colors = Theme.of(context).colorScheme;
    final connected = BleService.instance.isConnected;
    final connecting = BleService.instance.isReconnecting || _connecting;
    final statusText = connected
        ? "Connected"
        : connecting
        ? "Connecting..."
        : "Disconnected";
    final statusColor = connected
        ? Colors.green
        : connecting
        ? Colors.orange
        : Theme.of(context).colorScheme.error;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Pager Dashboard"),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Chip(
              avatar: Icon(
                connected
                    ? Icons.bluetooth_connected
                    : connecting
                    ? Icons.bluetooth_searching
                    : Icons.bluetooth_disabled,
                size: 16,
                color: statusColor,
              ),
              label: Text(statusText),
              side: BorderSide.none,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
              backgroundColor: colors.surfaceContainerHighest.withValues(
                alpha: 0.7,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              connected
                  ? Icons.bluetooth_connected
                  : connecting
                  ? Icons.bluetooth_searching
                  : Icons.bluetooth_disabled,
            ),
            onPressed: _connecting ? null : _connectToMaster,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAssignDialog,
        child: const Icon(Icons.add_rounded),
      ),
      body: ValueListenableBuilder(
        valueListenable: sessionBox.listenable(),
        builder: (context, Box<ActiveSession> box, _) {
          final sessions = box.values.toList();

          if (sessions.isEmpty) {
            return Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.inbox_outlined, size: 36),
                    SizedBox(height: 10),
                    Text("No active sessions", style: TextStyle(fontSize: 16)),
                  ],
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 100),
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];

              return SessionCard(
                session: session,
                onDelete: () => _deleteSession(session),
                onPreparingAction: (actionCode) {
                  _sendPreparingActionForSession(session, actionCode);
                },
                onStatusChange: () async {
                  if (session.status == "ready" &&
                      BleService.instance.isConnected) {
                    await _sendAlertForSession(session);
                  }
                },
              );
            },
          );
        },
      ),
    );
  }
}
