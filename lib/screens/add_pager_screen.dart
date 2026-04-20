import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/pager_device.dart';
import '../services/ble_service.dart';

class AddPagerScreen extends StatefulWidget {
  const AddPagerScreen({super.key});

  @override
  State<AddPagerScreen> createState() => _AddPagerScreenState();
}

class _AddPagerScreenState extends State<AddPagerScreen> {
  final macController = TextEditingController();
  final manualNumberController = TextEditingController();

  bool autoGenerate = true;
  bool _saving = false;
  StreamSubscription<String>? _bleMessageSub;

  @override
  void initState() {
    super.initState();
    _bleMessageSub = BleService.instance.messageStream.listen((message) {
      if (!mounted) return;
      if (message.startsWith("ACK: ADD:")) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    });
  }

  void _scanQR() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const _QRScannerPage()),
    );

    if (result != null && mounted) {
      setState(() {
        macController.text = result;
      });
    }
  }

  int _getNextPagerNumber(Box<PagerDevice> box) {
    if (box.isEmpty) return 1;
    final maxNumber = box.values
        .map((e) => e.pagerNumber)
        .reduce((a, b) => a > b ? a : b);
    return maxNumber + 1;
  }

  String? _normalizeMac(String input) {
    final cleaned = input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();

    if (cleaned.length != 12) return null;

    final parts = List.generate(6, (i) => cleaned.substring(i * 2, i * 2 + 2));

    return parts.join(':');
  }

  int? _extractPagerNumberFromAddResponse(String response) {
    final match = RegExp(r'#\s*(\d+)').firstMatch(response);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  Future<void> _savePager() async {
    if (_saving) return;

    final box = Hive.box<PagerDevice>('pagers');
    final mac = _normalizeMac(macController.text.trim());

    if (mac == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Invalid MAC. Use AA:BB:CC:DD:EE:FF")),
      );
      return;
    }

    final exists = box.values.any((p) => _normalizeMac(p.macAddress) == mac);

    if (exists) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("MAC already exists")));
      return;
    }

    int pagerNumber;

    if (autoGenerate) {
      pagerNumber = _getNextPagerNumber(box);
    } else {
      if (manualNumberController.text.isEmpty) return;

      pagerNumber = int.tryParse(manualNumberController.text) ?? 0;
      if (pagerNumber <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Enter a valid pager number")),
        );
        return;
      }

      if (box.values.any((p) => p.pagerNumber == pagerNumber)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Pager number already exists")),
        );
        return;
      }
    }

    if (!BleService.instance.isConnected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Connect to master first")));
      return;
    }

    setState(() => _saving = true);
    final response = await BleService.instance.addPager(mac);
    if (!mounted) return;
    setState(() => _saving = false);

    if (response == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No response from master. Try again.")),
      );
      return;
    }

    if (!response.startsWith("OK:")) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(response)));
      return;
    }

    final masterPagerNumber =
        _extractPagerNumberFromAddResponse(response) ?? pagerNumber;
    final pagerNumberConflict = box.values.any(
      (p) =>
          p.pagerNumber == masterPagerNumber &&
          _normalizeMac(p.macAddress) != mac,
    );
    if (pagerNumberConflict) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Master assigned pager #$masterPagerNumber, but local data conflicts. Run sync in Settings.",
          ),
        ),
      );
      return;
    }

    final pager = PagerDevice(
      macAddress: mac,
      pagerNumber: masterPagerNumber,
      isAssigned: false,
    );

    box.add(pager);

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(response)));
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _bleMessageSub?.cancel();
    macController.dispose();
    manualNumberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text("Register Pager")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _scanQR,
                borderRadius: BorderRadius.circular(22),
                child: Ink(
                  height: 170,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: LinearGradient(
                      colors: [
                        colors.primaryContainer.withValues(alpha: 0.55),
                        colors.secondaryContainer.withValues(alpha: 0.45),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.qr_code_scanner_rounded, size: 42),
                      SizedBox(height: 10),
                      Text(
                        "Tap to Scan QR",
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 25),

            TextField(
              controller: macController,
              decoration: const InputDecoration(
                labelText: "MAC Address",
                prefixIcon: Icon(Icons.developer_board_outlined),
              ),
            ),

            const SizedBox(height: 25),

            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment<bool>(
                    value: true,
                    icon: Icon(Icons.auto_fix_high_outlined),
                    label: Text("Auto Number"),
                  ),
                  ButtonSegment<bool>(
                    value: false,
                    icon: Icon(Icons.tune_rounded),
                    label: Text("Manual"),
                  ),
                ],
                selected: {autoGenerate},
                onSelectionChanged: (selection) {
                  setState(() => autoGenerate = selection.first);
                },
              ),
            ),

            if (!autoGenerate)
              TextField(
                controller: manualNumberController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: "Pager Number",
                  prefixIcon: Icon(Icons.numbers_outlined),
                ),
              ),

            const SizedBox(height: 35),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _savePager,
                child: Text(_saving ? "Registering..." : "Save Pager"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QRScannerPage extends StatefulWidget {
  const _QRScannerPage();

  @override
  State<_QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<_QRScannerPage> {
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

              if (barcode != null) {
                scanned = true;
                final navigator = Navigator.of(context);
                await controller.stop();

                if (!mounted) return;
                navigator.pop(barcode);
              }
            },
          ),

          // White overlay
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _ScannerOverlayPainter()),
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

class _ScannerOverlayPainter extends CustomPainter {
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
