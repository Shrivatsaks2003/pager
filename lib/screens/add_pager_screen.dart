import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/pager_device.dart';

class AddPagerScreen extends StatefulWidget {
  const AddPagerScreen({super.key});

  @override
  State<AddPagerScreen> createState() => _AddPagerScreenState();
}

class _AddPagerScreenState extends State<AddPagerScreen> {
  final macController = TextEditingController();
  final manualNumberController = TextEditingController();

  bool autoGenerate = true;

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
    final maxNumber =
        box.values.map((e) => e.pagerNumber).reduce((a, b) => a > b ? a : b);
    return maxNumber + 1;
  }

  void _savePager() {
    final box = Hive.box<PagerDevice>('pagers');
    final mac = macController.text.trim();

    if (mac.isEmpty) return;

    if (box.values.any((p) => p.macAddress == mac)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("MAC already exists")),
      );
      return;
    }

    int pagerNumber;

    if (autoGenerate) {
      pagerNumber = _getNextPagerNumber(box);
    } else {
      if (manualNumberController.text.isEmpty) return;

      pagerNumber = int.parse(manualNumberController.text);

      if (box.values.any((p) => p.pagerNumber == pagerNumber)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Pager number already exists")),
        );
        return;
      }
    }

    final pager = PagerDevice(
      macAddress: mac,
      pagerNumber: pagerNumber,
      isAssigned: false,
    );

    box.add(pager);

    Navigator.pop(context);
  }

  @override
  void dispose() {
    macController.dispose();
    manualNumberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Register Pager")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            GestureDetector(
              onTap: _scanQR,
              child: Container(
                height: 160,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.grey.shade400),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.qr_code_scanner, size: 40),
                    SizedBox(height: 10),
                    Text("Tap to Scan QR"),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 25),

            TextField(
              controller: macController,
              decoration: const InputDecoration(
                labelText: "MAC Address",
                border: OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 25),

            Row(
              children: [
                Expanded(
                  child: RadioListTile<bool>(
                    value: true,
                    groupValue: autoGenerate,
                    onChanged: (_) => setState(() => autoGenerate = true),
                    title: const Text("Auto Number"),
                  ),
                ),
                Expanded(
                  child: RadioListTile<bool>(
                    value: false,
                    groupValue: autoGenerate,
                    onChanged: (_) => setState(() => autoGenerate = false),
                    title: const Text("Manual"),
                  ),
                ),
              ],
            ),

            if (!autoGenerate)
              TextField(
                controller: manualNumberController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: "Pager Number",
                  border: OutlineInputBorder(),
                ),
              ),

            const SizedBox(height: 35),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _savePager,
                child: const Text("Save Pager"),
              ),
            )
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
              child: CustomPaint(
                painter: _ScannerOverlayPainter(),
              ),
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
    final paint = Paint()..color = Colors.white.withOpacity(0.85);

    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final cutout = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: 260,
      height: 260,
    );

    path.addRRect(
      RRect.fromRectAndRadius(cutout, const Radius.circular(20)),
    );

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
