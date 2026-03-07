import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/foundation.dart';

class BleService {
  BleService._();
  static final BleService instance = BleService._();

  // MUST match ESP32 UUIDs
  static const String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";

  static const String characteristicUuid =
      "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _deviceStateSub;
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  final StreamController<String> _messageController =
      StreamController<String>.broadcast();
  bool _isConnected = false;
  bool _manualDisconnect = false;
  bool _isReconnecting = false;
  DateTime? _reconnectUntil;
  String? _lastEmittedMessage;
  DateTime? _lastEmittedAt;

  bool get isConnected => _isConnected;
  bool get isReconnecting => _isReconnecting;
  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<String> get messageStream => _messageController.stream;

  // ========================= CONNECT =========================

  Future<bool> connect() async {
    _manualDisconnect = false;

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
          debugPrint("Device found: ${r.device.platformName}");

          // Match using advertised service UUID
          bool hasService = r.advertisementData.serviceUuids.any(
            (uuid) =>
                uuid.toString().toLowerCase() == serviceUuid.toLowerCase(),
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

      await foundDevice.connect(timeout: const Duration(seconds: 15));

      _device = foundDevice;
      _deviceStateSub = foundDevice.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleUnexpectedDisconnect();
        }
      });

      // Discover services
      List<BluetoothService> services = await foundDevice.discoverServices();

      for (BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase() ==
            serviceUuid.toLowerCase()) {
          for (BluetoothCharacteristic char in service.characteristics) {
            if (char.uuid.toString().toLowerCase() ==
                characteristicUuid.toLowerCase()) {
              _characteristic = char;

              // Enable notifications
              await char.setNotifyValue(true);

              _notifySub = char.lastValueStream.listen((value) {
                if (value.isEmpty) return;
                final response = utf8.decode(value);
                debugPrint("BLE Response: $response");
                if (_shouldEmitMessage(response)) {
                  _messageController.add(response);
                }
              });

              _setConnected();
              _isReconnecting = false;
              _reconnectUntil = null;
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

  Future<String?> sendAndWaitForResponse(
    String command, {
    Duration timeout = const Duration(seconds: 8),
    bool Function(String message)? match,
  }) async {
    final matcher = match ?? (_) => true;
    final completer = Completer<String?>();

    late final StreamSubscription<String> responseSub;
    responseSub = messageStream.listen((message) {
      if (matcher(message) && !completer.isCompleted) {
        completer.complete(message);
      }
    });

    final sent = await send(command);
    if (!sent) {
      await responseSub.cancel();
      return null;
    }

    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });

    final result = await completer.future;
    timer.cancel();
    await responseSub.cancel();
    return result;
  }

  Future<String?> addPager(String macAddress) {
    return sendAndWaitForResponse(
      "ADD:$macAddress",
      match: (message) =>
          message.startsWith("OK:") || message.startsWith("ERROR:"),
    );
  }

  // ========================= DISCONNECT =========================

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _isReconnecting = false;
    _reconnectUntil = null;
    _connectionController.add(false);
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
    final hadConnection =
        _isConnected || _device != null || _characteristic != null;

    _notifySub = null;
    _deviceStateSub = null;
    _device = null;
    _characteristic = null;
    _isConnected = false;
    _lastEmittedMessage = null;
    _lastEmittedAt = null;

    if (hadConnection) {
      _connectionController.add(false);
    }
  }

  void _handleUnexpectedDisconnect() {
    _setDisconnected();
    debugPrint("BLE link lost unexpectedly");
    _startReconnectWindow();
  }

  void _startReconnectWindow() {
    if (_manualDisconnect || _isReconnecting) return;

    _isReconnecting = true;
    _reconnectUntil = DateTime.now().add(const Duration(minutes: 1));
    _connectionController.add(false);

    unawaited(_reconnectUntilTimeout());
  }

  Future<void> _reconnectUntilTimeout() async {
    try {
      while (!_manualDisconnect &&
          !_isConnected &&
          _reconnectUntil != null &&
          DateTime.now().isBefore(_reconnectUntil!)) {
        debugPrint("Attempting BLE reconnect...");
        final connected = await connect();
        if (connected) {
          return;
        }

        await Future<void>.delayed(const Duration(seconds: 3));
      }
    } finally {
      _isReconnecting = false;
      _reconnectUntil = null;
      if (!_isConnected) {
        _connectionController.add(false);
      }
    }
  }

  void dispose() {
    _notifySub?.cancel();
    _deviceStateSub?.cancel();
    _connectionController.close();
    _messageController.close();
  }

  bool _shouldEmitMessage(String message) {
    final now = DateTime.now();
    final lastMessage = _lastEmittedMessage;
    final lastAt = _lastEmittedAt;

    _lastEmittedMessage = message;
    _lastEmittedAt = now;

    if (lastMessage == null || lastAt == null) return true;

    final elapsed = now.difference(lastAt);
    final isHeartbeatAck =
        message.contains("HEARTBEAT") && message.startsWith("SLAVE_ACK:");

    // Heartbeat ACKs can be very noisy; only emit at most once every 30s.
    if (isHeartbeatAck &&
        lastMessage == message &&
        elapsed < const Duration(seconds: 30)) {
      return false;
    }

    // Generic BLE duplicate burst protection.
    if (lastMessage == message && elapsed < const Duration(milliseconds: 800)) {
      return false;
    }

    return true;
  }
}
