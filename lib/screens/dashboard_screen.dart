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
  State<DashboardScreen> createState() =>
      _DashboardScreenState();
}

class _DashboardScreenState
    extends State<DashboardScreen> {
  bool _connecting = false;
  StreamSubscription<bool>? _bleConnectionSub;

  @override
  void initState() {
    super.initState();
    _bleConnectionSub =
        BleService.instance.connectionStream.listen((_) {
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
              ok ? "Connected to Master" : "Master not found"),
        ),
      );
    } else {
      await BleService.instance.disconnect();

      if (!mounted) return;

      setState(() {
        _connecting = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Disconnected")),
      );
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
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final availablePagers =
                pagerBox.values
                    .where((p) => !p.isAssigned)
                    .toList();

            return SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 20,
                  bottom:
                      MediaQuery.of(context)
                              .viewInsets
                              .bottom +
                          20,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      "Assign Pager",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),

                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: "Customer Name",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: phoneController,
                      decoration: const InputDecoration(
                        labelText: "Phone Number",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: orderController,
                      decoration: const InputDecoration(
                        labelText: "Order ID",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),

                    DropdownButtonFormField<int>(
                      decoration: const InputDecoration(
                        labelText: "Select Pager",
                        border: OutlineInputBorder(),
                      ),
                      value: selectedPagerNumber,
                      items: availablePagers
                          .map(
                            (pager) =>
                                DropdownMenuItem<int>(
                              value:
                                  pager.pagerNumber,
                              child: Text(
                                  "Pager ${pager.pagerNumber}"),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        setModalState(() {
                          selectedPagerNumber =
                              value;
                        });
                      },
                    ),
                    const SizedBox(height: 20),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          if (nameController
                                  .text.isEmpty ||
                              phoneController
                                  .text.isEmpty ||
                              orderController
                                  .text.isEmpty ||
                              selectedPagerNumber ==
                                  null) {
                            return;
                          }

                          final selectedPager =
                              pagerBox.values
                                  .firstWhere(
                            (p) =>
                                p.pagerNumber ==
                                selectedPagerNumber,
                          );

                          selectedPager
                              .isAssigned = true;
                          selectedPager.save();

                          final session =
                              ActiveSession(
                            orderId:
                                orderController.text,
                            customerName:
                                nameController.text,
                            phoneNumber:
                                phoneController.text,
                            pagerNumber:
                                selectedPagerNumber!,
                            createdAt:
                                DateTime.now(),
                          );

                          sessionBox.add(session);

                          Navigator.pop(context);
                        },
                        child:
                            const Text("Assign"),
                      ),
                    )
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

  void _deleteSession(
      ActiveSession session) {
    final pagerBox =
        Hive.box<PagerDevice>('pagers');

    final pager = pagerBox.values
        .firstWhere(
      (p) =>
          p.pagerNumber ==
          session.pagerNumber,
    );

    pager.isAssigned = false;
    pager.save();

    session.delete();
  }

  // ================= BUILD =================

  @override
  Widget build(BuildContext context) {
    final sessionBox =
        Hive.box<ActiveSession>('sessions');

    return Scaffold(
      appBar: AppBar(
        title: const Text("Pager Dashboard"),
        actions: [
          IconButton(
            icon: Icon(
              BleService.instance.isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
            ),
            onPressed:
                _connecting ? null : _connectToMaster,
          ),
        ],
      ),
      floatingActionButton:
          FloatingActionButton(
        onPressed: _openAssignDialog,
        child: const Icon(Icons.add),
      ),
      body: ValueListenableBuilder(
        valueListenable:
            sessionBox.listenable(),
        builder: (context,
            Box<ActiveSession> box, _) {
          final sessions =
              box.values.toList();

          if (sessions.isEmpty) {
            return const Center(
              child: Text(
                "No active sessions",
                style:
                    TextStyle(fontSize: 16),
              ),
            );
          }

          return ListView.builder(
            padding:
                const EdgeInsets.all(16),
            itemCount: sessions.length,
            itemBuilder:
                (context, index) {
              final session =
                  sessions[index];

              return SessionCard(
                session: session,
                onDelete: () =>
                    _deleteSession(
                        session),
                onStatusChange:
                    () async {
                  if (session.status ==
                          "ready" &&
                      BleService
                          .instance
                          .isConnected) {
                    final pagerBox =
                        Hive.box<
                                PagerDevice>(
                            'pagers');

                    final pager =
                        pagerBox.values
                            .firstWhere(
                      (p) =>
                          p.pagerNumber ==
                          session
                              .pagerNumber,
                    );

                    await BleService
                        .instance
                        .send(
                            pager.macAddress);
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
