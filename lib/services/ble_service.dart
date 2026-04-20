import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:pager/services/app_config_service.dart';

class MasterCsvFetchResult {
  final String? csv;
  final String? error;

  const MasterCsvFetchResult({this.csv, this.error});

  bool get isSuccess => csv != null && error == null;
}

class MasterRowsFetchResult {
  final List<MasterPagerCsvRow>? rows;
  final String? error;

  const MasterRowsFetchResult({this.rows, this.error});

  bool get isSuccess => rows != null && error == null;
}

class MasterPagerCsvRow {
  final int pagerNumber;
  final String serial;
  final String mac;
  final bool active;
  final String lastCommand;
  final String lastAck;
  final String lastAckTime;

  const MasterPagerCsvRow({
    required this.pagerNumber,
    required this.serial,
    required this.mac,
    required this.active,
    required this.lastCommand,
    required this.lastAck,
    required this.lastAckTime,
  });
}

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
  String? _lastError;

  bool get isConnected => _isConnected;
  bool get isReconnecting => _isReconnecting;
  String? get lastError => _lastError;
  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<String> get messageStream => _messageController.stream;

  // ========================= CONNECT =========================

  Future<bool> connect() async {
    _manualDisconnect = false;
    _lastError = null;

    try {
      debugPrint("=== BLE CONNECT STARTED ===");
      final authCode = AppConfigService.instance.masterAuthCode;
      if (authCode == null) {
        _lastError =
            "Save the master MAC address in Settings before connecting.";
        return false;
      }

      final state = await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              return BluetoothAdapterState.off;
            },
          );
      if (state != BluetoothAdapterState.on) {
        debugPrint("Bluetooth adapter is not ON");
        _lastError = "Bluetooth is turned off.";
        return false;
      }

      final foundDevice = await _scanForMaster();

      if (foundDevice == null) {
        debugPrint("Master not found in scan");
        _lastError =
            "Master '${AppConfigService.instance.masterBleName}' not found.";
        return false;
      }

      debugPrint("Connecting to ${foundDevice.remoteId}");

      try {
        await foundDevice.connect(timeout: const Duration(seconds: 15));
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (!msg.contains("already connected")) {
          rethrow;
        }
      }

      _device = foundDevice;
      _deviceStateSub = foundDevice.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleUnexpectedDisconnect();
        }
      });

      final characteristic = await _findMasterCharacteristic(foundDevice);
      if (characteristic == null) {
        debugPrint("Master characteristic not found");
        await _disconnectDuringSetup(foundDevice);
        _lastError ??= "Master service not found on device.";
        _setDisconnected();
        return false;
      }

      _characteristic = characteristic;
      await characteristic.setNotifyValue(true);
      _notifySub = characteristic.lastValueStream.listen((value) {
        if (value.isEmpty) return;
        final response = utf8.decode(value, allowMalformed: true);
        debugPrint("BLE Response: $response");
        if (_shouldEmitMessage(response)) {
          _messageController.add(response);
        }
      });

      final authenticated = await _authorizeConnection(authCode);
      if (!authenticated) {
        await _disconnectDuringSetup(foundDevice);
        _setDisconnected();
        return false;
      }

      _setConnected();
      _isReconnecting = false;
      _reconnectUntil = null;
      debugPrint("=== BLE CONNECTED ===");
      return true;
    } catch (e) {
      debugPrint("BLE Error: $e");
      _lastError ??= "BLE connection failed: $e";
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
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

  Future<String?> deletePager(int pagerNumber) {
    return sendAndWaitForResponse(
      "DELETE:$pagerNumber",
      match: (message) =>
          message.startsWith("OK:") || message.startsWith("ERROR:"),
    );
  }

  Future<String?> renameConnectedMaster(String newName) {
    return sendAndWaitForResponse(
      "SET_BLE_NAME:${newName.trim()}",
      match: (message) =>
          message.startsWith("OK:") || message.startsWith("ERROR:"),
    );
  }

  Future<MasterCsvFetchResult> fetchMasterCsvReport({
    Duration timeout = const Duration(seconds: 15),
    String command = "/MASTER_EXCEL",
  }) async {
    if (_characteristic == null || !_isConnected) {
      return const MasterCsvFetchResult(error: "Not connected to master");
    }

    final completer = Completer<MasterCsvFetchResult>();
    final csvBuffer = StringBuffer();
    bool started = false;

    late final StreamSubscription<String> responseSub;
    Timer? timer;

    void finish(MasterCsvFetchResult result) {
      if (completer.isCompleted) return;
      timer?.cancel();
      responseSub.cancel();
      completer.complete(result);
    }

    void consumeChunk(String payload) {
      final endIndex = payload.indexOf("\nCSV_END");
      if (endIndex >= 0) {
        csvBuffer.write(payload.substring(0, endIndex));
        finish(MasterCsvFetchResult(csv: csvBuffer.toString().trimRight()));
      } else {
        csvBuffer.write(payload);
      }
    }

    responseSub = messageStream.listen((message) {
      if (!started && message.startsWith("ERROR:")) {
        finish(MasterCsvFetchResult(error: message));
        return;
      }

      if (!started) {
        final startIndex = message.indexOf("CSV_START\n");
        if (startIndex < 0) return;

        started = true;
        final payload = message.substring(startIndex + 10);
        consumeChunk(payload);
        return;
      }

      consumeChunk(message);
    });

    final sent = await send(command);
    if (!sent) {
      finish(MasterCsvFetchResult(error: "Failed to request $command"));
      return completer.future;
    }

    timer = Timer(timeout, () {
      if (!started) {
        finish(
          const MasterCsvFetchResult(
            error: "Timed out waiting for CSV_START from master",
          ),
        );
      } else {
        finish(
          const MasterCsvFetchResult(
            error: "Timed out while receiving CSV_END from master",
          ),
        );
      }
    });

    return completer.future;
  }

  Future<MasterCsvFetchResult> fetchMasterJsonReport({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_characteristic == null || !_isConnected) {
      return const MasterCsvFetchResult(error: "Not connected to master");
    }

    final completer = Completer<MasterCsvFetchResult>();
    final jsonBuffer = StringBuffer();
    bool started = false;

    late final StreamSubscription<String> responseSub;
    Timer? timer;

    void finish(MasterCsvFetchResult result) {
      if (completer.isCompleted) return;
      timer?.cancel();
      responseSub.cancel();
      completer.complete(result);
    }

    void consumeChunk(String payload) {
      final endIndex = payload.indexOf("\nJSON_END");
      if (endIndex >= 0) {
        jsonBuffer.write(payload.substring(0, endIndex));
        finish(MasterCsvFetchResult(csv: jsonBuffer.toString().trimRight()));
      } else {
        jsonBuffer.write(payload);
      }
    }

    responseSub = messageStream.listen((message) {
      if (!started && message.startsWith("ERROR:")) {
        finish(MasterCsvFetchResult(error: message));
        return;
      }

      if (!started) {
        final startIndex = message.indexOf("JSON_START\n");
        if (startIndex < 0) return;

        started = true;
        final payload = message.substring(startIndex + 11);
        consumeChunk(payload);
        return;
      }

      consumeChunk(message);
    });

    final sent = await send("GET_REPORT");
    if (!sent) {
      finish(const MasterCsvFetchResult(error: "Failed to request GET_REPORT"));
      return completer.future;
    }

    timer = Timer(timeout, () {
      if (!started) {
        finish(
          const MasterCsvFetchResult(
            error: "Timed out waiting for JSON_START from master",
          ),
        );
      } else {
        finish(
          const MasterCsvFetchResult(
            error: "Timed out while receiving JSON_END from master",
          ),
        );
      }
    });

    return completer.future;
  }

  Future<MasterRowsFetchResult> fetchMasterRows() async {
    final csvResult = await fetchMasterCsvReport(command: "/MASTER_EXCEL");
    if (csvResult.isSuccess && csvResult.csv != null) {
      final rows = parseMasterCsv(csvResult.csv!);
      if (rows.isNotEmpty) return MasterRowsFetchResult(rows: rows);
    }

    final jsonResult = await fetchMasterJsonReport();
    if (jsonResult.isSuccess && jsonResult.csv != null) {
      try {
        final rows = parseMasterJson(jsonResult.csv!);
        return MasterRowsFetchResult(rows: rows);
      } catch (e) {
        return MasterRowsFetchResult(error: "JSON parse failed: $e");
      }
    }

    return MasterRowsFetchResult(
      error: csvResult.error ?? jsonResult.error ?? "Failed to load report",
    );
  }

  List<MasterPagerCsvRow> parseMasterCsv(String csvText) {
    final lines = const LineSplitter()
        .convert(csvText)
        .where((line) => line.trim().isNotEmpty)
        .toList();

    if (lines.isEmpty) return const [];

    final rows = <MasterPagerCsvRow>[];
    final dataLines = lines.first.toLowerCase().startsWith("pagernumber")
        ? lines.skip(1)
        : lines;

    for (final line in dataLines) {
      final cells = _splitCsvLine(line);
      if (cells.length < 7) continue;

      final pagerNumber = int.tryParse(cells[0].trim());
      final serial = cells[1].trim();
      final mac = cells[2].trim().toUpperCase();
      final activeRaw = cells[3].trim().toUpperCase();

      if (pagerNumber == null || mac.isEmpty) continue;

      rows.add(
        MasterPagerCsvRow(
          pagerNumber: pagerNumber,
          serial: serial,
          mac: mac,
          active: activeRaw == "YES" || activeRaw == "TRUE" || activeRaw == "1",
          lastCommand: cells[4].trim(),
          lastAck: cells[5].trim(),
          lastAckTime: cells[6].trim(),
        ),
      );
    }

    return rows;
  }

  List<MasterPagerCsvRow> parseMasterJson(String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) return const [];

    final pagers = decoded["pagers"];
    if (pagers is! List) return const [];

    final rows = <MasterPagerCsvRow>[];
    for (final item in pagers) {
      if (item is! Map) continue;
      final pagerNumber = int.tryParse("${item["pagerNumber"] ?? ""}");
      final serial = "${item["serial"] ?? ""}";
      final mac = "${item["mac"] ?? ""}".toUpperCase();
      final activeRaw = "${item["active"] ?? false}".toLowerCase();
      final active =
          activeRaw == "true" || activeRaw == "1" || activeRaw == "yes";
      final lastCommand = "${item["lastCommand"] ?? ""}";
      final lastAck = "${item["lastACK"] ?? ""}";
      final lastAckTime = "${item["lastACKTime"] ?? ""}";

      if (pagerNumber == null || mac.isEmpty) continue;
      rows.add(
        MasterPagerCsvRow(
          pagerNumber: pagerNumber,
          serial: serial,
          mac: mac,
          active: active,
          lastCommand: lastCommand,
          lastAck: lastAck,
          lastAckTime: lastAckTime,
        ),
      );
    }
    return rows;
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

  Future<BluetoothDevice?> _scanForMaster() async {
    BluetoothDevice? found;
    final targetName = AppConfigService.instance.masterBleName;

    Future<void> runScan({
      required Duration timeout,
      List<Guid> withServices = const [],
      required bool Function(ScanResult r) match,
    }) async {
      if (found != null) return;

      await FlutterBluePlus.startScan(
        timeout: timeout,
        withServices: withServices,
      );

      try {
        await for (final results in FlutterBluePlus.scanResults) {
          for (final r in results) {
            if (!match(r)) continue;
            found = r.device;
            break;
          }
          if (found != null) break;
        }
      } finally {
        await FlutterBluePlus.stopScan();
      }
    }

    // Pass 1: service UUID filtered (fast + precise when advertised correctly)
    await runScan(
      timeout: const Duration(seconds: 8),
      withServices: [Guid(serviceUuid)],
      match: (r) {
        final hasService = r.advertisementData.serviceUuids.any(
          (uuid) => uuid.toString().toLowerCase() == serviceUuid.toLowerCase(),
        );
        return hasService;
      },
    );
    if (found != null) return found;

    // Pass 2: fallback by device name (ESP32 advertising sometimes misses UUID)
    await runScan(
      timeout: const Duration(seconds: 8),
      match: (r) {
        final advName = r.advertisementData.advName.trim();
        final platformName = r.device.platformName.trim();
        return advName == targetName || platformName == targetName;
      },
    );

    return found;
  }

  Future<void> _disconnectDuringSetup(BluetoothDevice device) async {
    final previousManualDisconnect = _manualDisconnect;
    _manualDisconnect = true;
    try {
      await _notifySub?.cancel();
      await _deviceStateSub?.cancel();
      await device.disconnect();
    } catch (_) {
      // Ignore cleanup errors during failed setup.
    } finally {
      _manualDisconnect = previousManualDisconnect;
    }
  }

  Future<bool> _authorizeConnection(String authCode) async {
    final response = await sendAndWaitForResponse(
      "AUTH:$authCode",
      timeout: const Duration(seconds: 5),
      match: (message) =>
          message.startsWith("AUTH_OK:") || message.startsWith("ERROR:"),
    );

    if (response == null) {
      _lastError = "Master authorization timed out.";
      return false;
    }

    if (response.startsWith("AUTH_OK:")) {
      return true;
    }

    _lastError = response;
    return false;
  }

  Future<BluetoothCharacteristic?> _findMasterCharacteristic(
    BluetoothDevice device,
  ) async {
    for (int attempt = 0; attempt < 3; attempt++) {
      final services = await device.discoverServices();
      for (final service in services) {
        if (service.uuid.toString().toLowerCase() != serviceUuid) continue;
        for (final char in service.characteristics) {
          if (char.uuid.toString().toLowerCase() == characteristicUuid) {
            return char;
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return null;
  }

  List<String> _splitCsvLine(String line) {
    final cells = <String>[];
    final current = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final char = line[i];

      if (char == '"') {
        final isEscapedQuote =
            inQuotes && i + 1 < line.length && line[i + 1] == '"';
        if (isEscapedQuote) {
          current.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
        continue;
      }

      if (char == ',' && !inQuotes) {
        cells.add(current.toString());
        current.clear();
        continue;
      }

      current.write(char);
    }

    cells.add(current.toString());
    return cells;
  }
}
