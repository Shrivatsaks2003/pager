import 'package:hive_flutter/hive_flutter.dart';

class AppConfigService {
  AppConfigService._();

  static final AppConfigService instance = AppConfigService._();

  static const String boxName = 'app_settings';
  static const String defaultMasterName = 'Restaurant_Master';
  static const String _masterBleNameKey = 'master_ble_name';
  static const String _masterAuthCodeKey = 'master_auth_code';
  static const String _masterMacAddressKey = 'master_mac_address';

  Box<String> get _box => Hive.box<String>(boxName);

  String get masterBleName {
    final saved = _box.get(_masterBleNameKey)?.trim();
    if (saved == null || saved.isEmpty) return defaultMasterName;
    return saved;
  }

  String? get masterMacAddress {
    final saved = _box.get(_masterMacAddressKey);
    if (saved == null) return null;
    return normalizeMacAddress(saved);
  }

  String? get masterAuthCode {
    final mac = masterMacAddress;
    if (mac != null) {
      return extractAuthCodeFromMac(mac);
    }

    // Backward compatibility with older builds that stored only the auth code.
    final legacyAuthCode = _box.get(_masterAuthCodeKey);
    if (legacyAuthCode == null) return null;
    return normalizeAuthCode(legacyAuthCode);
  }

  Future<void> saveMasterBleName(String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      await _box.delete(_masterBleNameKey);
      return;
    }
    await _box.put(_masterBleNameKey, normalized);
  }

  Future<void> saveMasterMacAddress(String macAddress) async {
    final normalized = normalizeMacAddress(macAddress);
    if (normalized == null) {
      throw ArgumentError(
        'Master MAC address must contain exactly 12 hex characters.',
      );
    }
    await _box.put(_masterMacAddressKey, normalized);
    await _box.delete(_masterAuthCodeKey);
  }

  String? normalizeAuthCode(String input) {
    final cleaned = input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (cleaned.length != 4) return null;
    return cleaned;
  }

  String? normalizeMacAddress(String input) {
    final cleaned = input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (cleaned.length != 12) return null;

    final parts = List.generate(6, (i) => cleaned.substring(i * 2, i * 2 + 2));
    return parts.join(':');
  }

  String? extractAuthCodeFromMac(String input) {
    final cleaned = input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (cleaned.length == 4) return cleaned;
    if (cleaned.length != 12) return null;
    return cleaned.substring(cleaned.length - 4);
  }
}
