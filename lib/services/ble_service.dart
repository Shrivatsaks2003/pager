import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/foundation.dart';

class BleService {
  BleService._();
  static final BleService instance = BleService._();

  // MUST match ESP32 UUIDs
  static const String serviceUuid =
      "4fafc201-1fb5-459e-8fcc-c5c9c331914b";

  static const String characteristicUuid =
      "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>?
      _deviceStateSub;
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  bool _isConnected = false;

  bool get isConnected => _isConnected;
  Stream<bool> get connectionStream =>
      _connectionController.stream;

  // ========================= CONNECT =========================

  Future<bool> connect() async {
    try {
      debugPrint("=== BLE CONNECT STARTED ===");

      // Ensure Bluetooth is ON
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        debugPrint("Bluetooth is OFF");
        return false;
      }

      BluetoothDevice? foundDevice;

      // Scan ONLY for devices advertising our service UUID
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        withServices: [Guid(serviceUuid)],
      );

      await for (var results in FlutterBluePlus.scanResults) {
        for (ScanResult r in results) {
          debugPrint(
              "Device found: ${r.device.platformName}");

          // Match using advertised service UUID
          bool hasService = r.advertisementData.serviceUuids.any(
            (uuid) =>
                uuid.toString().toLowerCase() ==
                serviceUuid.toLowerCase(),
          );

          if (hasService) {
            foundDevice = r.device;
            break;
          }
        }

        if (foundDevice != null) break;
      }

      await FlutterBluePlus.stopScan();

      if (foundDevice == null) {
        debugPrint("Master not found (UUID not detected)");
        return false;
      }

      debugPrint("Connecting to ${foundDevice.remoteId}");

      await foundDevice.connect(
        timeout: const Duration(seconds: 15),
      );

      _device = foundDevice;
      _deviceStateSub = foundDevice.connectionState.listen(
        (state) {
          if (state ==
              BluetoothConnectionState.disconnected) {
            _handleUnexpectedDisconnect();
          }
        },
      );

      // Discover services
      List<BluetoothService> services =
          await foundDevice.discoverServices();

      for (BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase() ==
            serviceUuid.toLowerCase()) {
          for (BluetoothCharacteristic char
              in service.characteristics) {
            if (char.uuid
                    .toString()
                    .toLowerCase() ==
                characteristicUuid.toLowerCase()) {
              _characteristic = char;

              // Enable notifications
              await char.setNotifyValue(true);

              _notifySub =
                  char.lastValueStream.listen(
                (value) {
                  final response =
                      utf8.decode(value);
                  debugPrint(
                      "BLE Response: $response");
                },
              );

              _setConnected();
              debugPrint("=== BLE CONNECTED ===");
              return true;
            }
          }
        }
      }

      debugPrint("Characteristic not found");
      await foundDevice.disconnect();
      _setDisconnected();
      return false;
    } catch (e) {
      debugPrint("BLE Error: $e");
      _setDisconnected();
      return false;
    }
  }

  // ========================= SEND =========================

  Future<bool> send(String command) async {
    if (_characteristic == null) {
      debugPrint("Not connected");
      return false;
    }

    try {
      await _characteristic!.write(
        utf8.encode(command),
        withoutResponse: false,
      );

      debugPrint("Sent: $command");
      return true;
    } catch (e) {
      debugPrint("Send error: $e");
      return false;
    }
  }

  // ========================= DISCONNECT =========================

  Future<void> disconnect() async {
    final device = _device;

    try {
      await _notifySub?.cancel();
      await _deviceStateSub?.cancel();
      await device?.disconnect();
    } catch (_) {}

    _setDisconnected();

    debugPrint("BLE Disconnected");
  }

  void _setConnected() {
    if (_isConnected) return;
    _isConnected = true;
    _connectionController.add(true);
  }

  void _setDisconnected() {
    final hadConnection = _isConnected ||
        _device != null ||
        _characteristic != null;

    _notifySub = null;
    _deviceStateSub = null;
    _device = null;
    _characteristic = null;
    _isConnected = false;

    if (hadConnection) {
      _connectionController.add(false);
    }
  }

  void _handleUnexpectedDisconnect() {
    _setDisconnected();
    debugPrint("BLE link lost unexpectedly");
  }

  void dispose() {
    _notifySub?.cancel();
    _deviceStateSub?.cancel();
    _connectionController.close();
  }
}
