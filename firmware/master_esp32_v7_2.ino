// MASTER ESP32 - Restaurant Pager System v7.2 (Merged + Fixed)

#include <esp_now.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Preferences.h>
#include <SPIFFS.h>
#include <ArduinoJson.h>
#include <ctype.h>

// BLE UUIDs
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;
bool clientAuthenticated = false;
unsigned long bleConnectedAt = 0;
unsigned long pendingDisconnectAt = 0;
unsigned long pendingRestartAt = 0;
String bleDeviceName = "Restaurant_Master";

Preferences preferences;

// Pin Definitions
#define SETUP_SWITCH_PIN 15
#define STATUS_LED_PIN 2

// Maximum number of pagers
#define MAX_PAGERS 50

// SPIFFS file paths
#define REPORT_JSON "/pagers.json"
#define REPORT_CSV  "/master_excel"

// Serial number label length
#define SERIAL_LEN 16

// Heartbeat settings
#define HEARTBEAT_INTERVAL 5000
#define AUTH_TIMEOUT_MS 5000
unsigned long lastHeartbeatTime = 0;

// Structure for pager data
struct PagerInfo {
  uint8_t mac[6];
  bool active;
  char serialNum[SERIAL_LEN];
  char lastCommand[32];
  char lastACK[32];
  char lastACKTime[24];
};

PagerInfo pagers[MAX_PAGERS];
int pagerCount = 0;

// ESP-NOW message structure (must match slave)
typedef struct struct_message {
  char command[32];
  int duration;
  char status[64];
  bool ack;
} struct_message;

struct_message outgoingMessage;

// Mode tracking
bool setupMode = false;
bool lastSwitchState = HIGH;
unsigned long lastDebounceTime = 0;
unsigned long debounceDelay = 50;

// LED blink for setup mode
unsigned long lastBlinkTime = 0;
bool ledState = false;

// ==================== FORWARD DECLARATIONS ====================

void processSetupCommand(String command);
void processPagingCommand(String command);
void sendBLEResponse(String message);
bool isDigitsOnly(const String &s);
String sanitizeBleName(String input);
String getMasterAuthCode();
void loadBleConfig();
void saveBleName(String name);
void scheduleBleDisconnect(String reason);
void savePagersToFlash();
void loadPagersFromFlash();
void writeJSON();
void writeCSV();
void sendJSONOverBLE();
void sendCSVOverBLE();
void printCSVToSerial();
void logCommandSent(int pagerIdx, const char *cmd);
void logACKReceived(int pagerIdx, const char *ackStatus);
String getTimestamp();

// ==================== BLE CALLBACKS ====================

class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    clientAuthenticated = false;
    bleConnectedAt = millis();
    pendingDisconnectAt = 0;
    Serial.println("BLE Client Connected");
  };

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    clientAuthenticated = false;
    pendingDisconnectAt = 0;
    Serial.println("BLE Client Disconnected");
  }
};

class MyCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    std::string value = pCharacteristic->getValue();

    if (value.length() == 0) return;

    String command = String(value.c_str());
    command.trim();

    Serial.println("Received via BLE: " + command);

    String cmdUpper = command;
    cmdUpper.toUpperCase();

    if (cmdUpper.startsWith("AUTH:")) {
      String providedCode = command.substring(5);
      providedCode.trim();
      providedCode.toUpperCase();

      if (providedCode == getMasterAuthCode()) {
        clientAuthenticated = true;
        sendBLEResponse("AUTH_OK:" + providedCode);
        Serial.println("BLE client authenticated");
      } else {
        sendBLEResponse("ERROR: Invalid authorization code");
        scheduleBleDisconnect("Invalid BLE auth");
      }
      return;
    }

    if (!clientAuthenticated) {
      sendBLEResponse("ERROR: AUTH required");
      scheduleBleDisconnect("Missing BLE auth");
      return;
    }

    sendBLEResponse("ACK: " + command + " received");

    if (cmdUpper == "GET_REPORT") {
      sendJSONOverBLE();
      return;
    }

    if (cmdUpper == "/MASTER_EXCEL" || cmdUpper == "MASTER_EXCEL") {
      sendCSVOverBLE();
      return;
    }

    if (cmdUpper.startsWith("SET_SERIAL:")) {
      String rest = command.substring(11);
      int colon = rest.indexOf(':');
      if (colon <= 0) {
        sendBLEResponse("ERROR: SET_SERIAL format: SET_SERIAL:<NUM>:<LABEL>");
        return;
      }

      String numStr = rest.substring(0, colon);
      String label  = rest.substring(colon + 1);
      numStr.trim();
      label.trim();

      if (!isDigitsOnly(numStr)) {
        sendBLEResponse("ERROR: Invalid pager number");
        return;
      }

      int idx = numStr.toInt() - 1;
      if (idx < 0 || idx >= pagerCount) {
        sendBLEResponse("ERROR: Pager not found");
        return;
      }

      strncpy(pagers[idx].serialNum, label.c_str(), SERIAL_LEN - 1);
      pagers[idx].serialNum[SERIAL_LEN - 1] = '\0';
      savePagersToFlash();
      sendBLEResponse("OK: Serial for Pager #" + String(idx + 1) + " set to " + label);
      return;
    }

    if (cmdUpper.startsWith("SET_BLE_NAME:")) {
      String requestedName = sanitizeBleName(command.substring(13));
      if (requestedName.length() == 0) {
        sendBLEResponse("ERROR: BLE name cannot be empty");
        return;
      }

      saveBleName(requestedName);
      sendBLEResponse("OK: BLE name updated to " + requestedName);
      pendingRestartAt = millis() + 600;
      return;
    }

    if (cmdUpper.startsWith("ADD:") ||
        cmdUpper == "LIST" ||
        cmdUpper.startsWith("DELETE:") ||
        cmdUpper == "CLEAR") {
      processSetupCommand(command);
    } else {
      processPagingCommand(command);
    }
  }
};

// ==================== STORAGE ====================

void savePagersToFlash() {
  preferences.begin("pagers", false);
  preferences.putInt("count", pagerCount);

  for (int i = 0; i < pagerCount; i++) {
    String macStr = "";
    for (int j = 0; j < 6; j++) {
      if (pagers[i].mac[j] < 16) macStr += "0";
      macStr += String(pagers[i].mac[j], HEX);
    }
    preferences.putString(("mac" + String(i)).c_str(), macStr);
    preferences.putBool(("active" + String(i)).c_str(), pagers[i].active);
    preferences.putString(("sn" + String(i)).c_str(), pagers[i].serialNum);
    preferences.putString(("lc" + String(i)).c_str(), pagers[i].lastCommand);
    preferences.putString(("la" + String(i)).c_str(), pagers[i].lastACK);
    preferences.putString(("lt" + String(i)).c_str(), pagers[i].lastACKTime);
  }

  preferences.end();
  Serial.println("Pagers saved to flash memory");

  writeJSON();
  writeCSV();
}

void loadPagersFromFlash() {
  preferences.begin("pagers", true);
  pagerCount = preferences.getInt("count", 0);
  if (pagerCount > MAX_PAGERS) pagerCount = MAX_PAGERS;

  for (int i = 0; i < pagerCount; i++) {
    String macStr = preferences.getString(("mac" + String(i)).c_str(), "");

    if (macStr.length() == 12) {
      for (int j = 0; j < 6; j++) {
        String byteStr = macStr.substring(j * 2, j * 2 + 2);
        pagers[i].mac[j] = strtol(byteStr.c_str(), NULL, 16);
      }
    } else {
      memset(pagers[i].mac, 0, 6);
    }

    pagers[i].active = preferences.getBool(("active" + String(i)).c_str(), true);

    String sn = preferences.getString(("sn" + String(i)).c_str(), "");
    String lc = preferences.getString(("lc" + String(i)).c_str(), "");
    String la = preferences.getString(("la" + String(i)).c_str(), "");
    String lt = preferences.getString(("lt" + String(i)).c_str(), "");

    strncpy(pagers[i].serialNum, sn.c_str(), SERIAL_LEN - 1);
    pagers[i].serialNum[SERIAL_LEN - 1] = '\0';
    strncpy(pagers[i].lastCommand, lc.c_str(), sizeof(pagers[i].lastCommand) - 1);
    pagers[i].lastCommand[sizeof(pagers[i].lastCommand) - 1] = '\0';
    strncpy(pagers[i].lastACK, la.c_str(), sizeof(pagers[i].lastACK) - 1);
    pagers[i].lastACK[sizeof(pagers[i].lastACK) - 1] = '\0';
    strncpy(pagers[i].lastACKTime, lt.c_str(), sizeof(pagers[i].lastACKTime) - 1);
    pagers[i].lastACKTime[sizeof(pagers[i].lastACKTime) - 1] = '\0';

    if (strlen(pagers[i].serialNum) == 0) {
      snprintf(pagers[i].serialNum, SERIAL_LEN, "S%03d", i + 1);
    }
  }

  preferences.end();
  Serial.println("Loaded " + String(pagerCount) + " pagers from flash memory");
}

// ==================== MAC HELPERS ====================

bool parseMacAddress(String macStr, uint8_t *macArray) {
  macStr.replace(":", "");
  macStr.toUpperCase();
  if (macStr.length() != 12) return false;

  for (int i = 0; i < 12; i++) {
    char c = macStr.charAt(i);
    if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) return false;
  }

  for (int i = 0; i < 6; i++) {
    String byteStr = macStr.substring(i * 2, i * 2 + 2);
    macArray[i] = strtol(byteStr.c_str(), NULL, 16);
  }
  return true;
}

String macToString(uint8_t *mac) {
  String macStr = "";
  for (int i = 0; i < 6; i++) {
    if (mac[i] < 16) macStr += "0";
    macStr += String(mac[i], HEX);
    if (i < 5) macStr += ":";
  }
  macStr.toUpperCase();
  return macStr;
}

bool isHexString(String str) {
  for (int i = 0; i < str.length(); i++) {
    char c = str.charAt(i);
    if (!((c >= '0' && c <= '9') ||
          (c >= 'A' && c <= 'F') ||
          (c >= 'a' && c <= 'f'))) {
      return false;
    }
  }
  return true;
}

bool isDigitsOnly(const String &s) {
  if (s.length() == 0) return false;
  for (int i = 0; i < s.length(); i++) {
    if (!isdigit((unsigned char)s.charAt(i))) return false;
  }
  return true;
}

String sanitizeBleName(String input) {
  input.trim();
  String out = "";
  for (int i = 0; i < input.length(); i++) {
    char c = input.charAt(i);
    if ((unsigned char)c < 32 || (unsigned char)c > 126) continue;
    out += c;
    if (out.length() >= 24) break;
  }
  out.trim();
  return out;
}

String getMasterAuthCode() {
  String mac = WiFi.macAddress();
  mac.replace(":", "");
  mac.toUpperCase();
  if (mac.length() < 4) return "0000";
  return mac.substring(mac.length() - 4);
}

void loadBleConfig() {
  preferences.begin("master_cfg", true);
  bleDeviceName = sanitizeBleName(
    preferences.getString("ble_name", "Restaurant_Master")
  );
  preferences.end();

  if (bleDeviceName.length() == 0) {
    bleDeviceName = "Restaurant_Master";
  }
}

void saveBleName(String name) {
  bleDeviceName = sanitizeBleName(name);
  if (bleDeviceName.length() == 0) {
    bleDeviceName = "Restaurant_Master";
  }

  preferences.begin("master_cfg", false);
  preferences.putString("ble_name", bleDeviceName);
  preferences.end();

  Serial.println("BLE name saved: " + bleDeviceName);
}

void scheduleBleDisconnect(String reason) {
  Serial.println("Scheduling BLE disconnect: " + reason);
  pendingDisconnectAt = millis() + 300;
}

// ==================== BLE RESPONSE ====================

void sendBLEResponse(String message) {
  if (deviceConnected) {
    pCharacteristic->setValue(message.c_str());
    pCharacteristic->notify();
  }
  Serial.println(message);
}

// ==================== REPORT HELPERS ====================

String getTimestamp() {
  unsigned long ms = millis();
  unsigned long s  = ms / 1000;
  unsigned long m  = s / 60;
  unsigned long h  = m / 60;
  char buf[24];
  snprintf(buf, sizeof(buf), "%02lu:%02lu:%02lu", h % 24, m % 60, s % 60);
  return String(buf);
}

void writeJSON() {
  JsonDocument doc;
  doc["totalPagers"] = pagerCount;
  doc["generatedAt"] = getTimestamp();

  JsonArray pagersArray = doc["pagers"].to<JsonArray>();
  for (int i = 0; i < pagerCount; i++) {
    JsonObject p = pagersArray.add<JsonObject>();
    p["pagerNumber"] = i + 1;
    p["serial"] = pagers[i].serialNum;
    p["mac"] = macToString(pagers[i].mac);
    p["active"] = pagers[i].active;
    p["lastCommand"] = pagers[i].lastCommand;
    p["lastACK"] = pagers[i].lastACK;
    p["lastACKTime"] = pagers[i].lastACKTime;
  }

  File f = SPIFFS.open(REPORT_JSON, FILE_WRITE);
  if (!f) {
    Serial.println("ERROR: Cannot write " + String(REPORT_JSON));
    return;
  }
  size_t bytesWritten = serializeJson(doc, f);
  f.close();
  Serial.println("JSON written to SPIFFS (" + String(bytesWritten) + " bytes)");
}

void sendJSONOverBLE() {
  if (!deviceConnected) return;

  File f = SPIFFS.open(REPORT_JSON, FILE_READ);
  if (!f) {
    sendBLEResponse("ERROR: No report file - add pagers first");
    return;
  }

  String json = "";
  while (f.available()) json += (char)f.read();
  f.close();

  if (json.length() == 0) {
    sendBLEResponse("ERROR: Report file is empty");
    return;
  }

  const int CHUNK = 512;
  int total = json.length();
  int parts = (total + CHUNK - 1) / CHUNK;

  for (int i = 0; i < parts; i++) {
    String chunk = json.substring(i * CHUNK, min((i + 1) * CHUNK, total));
    if (i == 0) chunk = "JSON_START\n" + chunk;
    if (i == parts - 1) chunk = chunk + "\nJSON_END";
    pCharacteristic->setValue(chunk.c_str());
    pCharacteristic->notify();
    delay(50);
  }

  Serial.println("GET_REPORT: sent " + String(parts) + " chunk(s), " + String(total) + " bytes");
}

void writeCSV() {
  File f = SPIFFS.open(REPORT_CSV, FILE_WRITE);
  if (!f) {
    Serial.println("ERROR: Cannot write " + String(REPORT_CSV));
    return;
  }

  f.println("PagerNumber,Serial#,MAC,Active,LastCommand,LastACK,LastACKTime");
  for (int i = 0; i < pagerCount; i++) {
    f.print(i + 1);                               f.print(",");
    f.print(pagers[i].serialNum);                 f.print(",");
    f.print(macToString(pagers[i].mac));          f.print(",");
    f.print(pagers[i].active ? "YES" : "NO");     f.print(",");
    f.print(pagers[i].lastCommand);               f.print(",");
    f.print(pagers[i].lastACK);                   f.print(",");
    f.println(pagers[i].lastACKTime);
  }

  f.close();
  Serial.println("CSV updated in SPIFFS (" + String(REPORT_CSV) + ")");
}

void sendCSVOverBLE() {
  if (!deviceConnected) return;

  File f = SPIFFS.open(REPORT_CSV, FILE_READ);
  if (!f) {
    sendBLEResponse("ERROR: /master_excel not found - add pagers first");
    return;
  }

  String csv = "";
  while (f.available()) csv += (char)f.read();
  f.close();

  if (csv.length() == 0) {
    sendBLEResponse("ERROR: /master_excel is empty - add pagers first");
    return;
  }

  const int CHUNK = 512;
  int total = csv.length();
  int parts = (total + CHUNK - 1) / CHUNK;

  for (int i = 0; i < parts; i++) {
    String chunk = csv.substring(i * CHUNK, min((i + 1) * CHUNK, total));
    if (i == 0) chunk = "CSV_START\n" + chunk;
    if (i == parts - 1) chunk = chunk + "\nCSV_END";
    pCharacteristic->setValue(chunk.c_str());
    pCharacteristic->notify();
    delay(50);
  }

  Serial.println("/master_excel sent over BLE: " + String(parts) + " chunk(s), " + String(total) + " bytes");
}

void printCSVToSerial() {
  File f = SPIFFS.open(REPORT_CSV, FILE_READ);
  if (!f) {
    Serial.println("ERROR: /master_excel not found in SPIFFS");
    return;
  }

  Serial.println("\n===== /master_excel =====");
  while (f.available()) Serial.write(f.read());
  Serial.println("\n=========================\n");
  f.close();
}

void logCommandSent(int pagerIdx, const char *cmd) {
  if (pagerIdx < 0 || pagerIdx >= pagerCount) return;
  strncpy(pagers[pagerIdx].lastCommand, cmd, sizeof(pagers[pagerIdx].lastCommand) - 1);
  pagers[pagerIdx].lastCommand[sizeof(pagers[pagerIdx].lastCommand) - 1] = '\0';
  writeJSON();
  writeCSV();
}

void logACKReceived(int pagerIdx, const char *ackStatus) {
  if (pagerIdx < 0 || pagerIdx >= pagerCount) return;
  strncpy(pagers[pagerIdx].lastACK, ackStatus, sizeof(pagers[pagerIdx].lastACK) - 1);
  pagers[pagerIdx].lastACK[sizeof(pagers[pagerIdx].lastACK) - 1] = '\0';
  String ts = getTimestamp();
  strncpy(pagers[pagerIdx].lastACKTime, ts.c_str(), sizeof(pagers[pagerIdx].lastACKTime) - 1);
  pagers[pagerIdx].lastACKTime[sizeof(pagers[pagerIdx].lastACKTime) - 1] = '\0';
  writeJSON();
  writeCSV();
}

// ==================== PAGER MANAGEMENT ====================

int addPager(uint8_t *mac) {
  for (int i = 0; i < pagerCount; i++) {
    if (memcmp(pagers[i].mac, mac, 6) == 0) {
      pagers[i].active = true;
      savePagersToFlash();

      esp_now_del_peer(mac);
      delay(50);

      esp_now_peer_info_t peerInfo = {};
      memcpy(peerInfo.peer_addr, mac, 6);
      peerInfo.channel = 1;
      peerInfo.encrypt = false;
      esp_now_add_peer(&peerInfo);

      return i + 1;
    }
  }

  if (pagerCount >= MAX_PAGERS) return -1;

  memcpy(pagers[pagerCount].mac, mac, 6);
  pagers[pagerCount].active = true;
  snprintf(pagers[pagerCount].serialNum, SERIAL_LEN, "S%03d", pagerCount + 1);
  pagers[pagerCount].lastCommand[0] = '\0';
  pagers[pagerCount].lastACK[0] = '\0';
  pagers[pagerCount].lastACKTime[0] = '\0';
  pagerCount++;
  savePagersToFlash();

  esp_now_peer_info_t peerInfo = {};
  memcpy(peerInfo.peer_addr, mac, 6);
  peerInfo.channel = 1;
  peerInfo.encrypt = false;
  esp_now_add_peer(&peerInfo);

  return pagerCount;
}

// Real delete: remove row and shift array so CSV + numbering stay clean
bool deletePager(int number) {
  if (number < 1 || number > pagerCount) return false;

  int idx = number - 1;
  esp_now_del_peer(pagers[idx].mac);

  for (int i = idx; i < pagerCount - 1; i++) {
    pagers[i] = pagers[i + 1];
  }
  pagerCount--;

  savePagersToFlash();
  return true;
}

void listPagers() {
  String response = "=== Registered Pagers ===\n";
  int activeCount = 0;

  for (int i = 0; i < pagerCount; i++) {
    if (pagers[i].active) {
      response += "Pager #" + String(i + 1) + " [" + String(pagers[i].serialNum) + "]: " + macToString(pagers[i].mac) + "\n";
      activeCount++;
    }
  }

  response += "Total: " + String(activeCount) + " active pagers";
  sendBLEResponse(response);
}

void clearAllPagers() {
  for (int i = 0; i < pagerCount; i++) {
    esp_now_del_peer(pagers[i].mac);
  }

  pagerCount = 0;
  preferences.begin("pagers", false);
  preferences.clear();
  preferences.end();

  writeJSON();
  writeCSV();
  sendBLEResponse("All pagers cleared");
}

// ==================== ESP-NOW CALLBACKS ====================

void OnDataSent(const uint8_t *mac_addr, esp_now_send_status_t status) {
  Serial.print("Send to ");
  for (int i = 0; i < 6; i++) {
    Serial.printf("%02X", mac_addr[i]);
    if (i < 5) Serial.print(":");
  }
  Serial.print(" - Status: ");
  Serial.println(status == ESP_NOW_SEND_SUCCESS ? "Success" : "FAIL");
}

void OnDataRecv(const uint8_t *mac_addr, const uint8_t *data, int len) {
  if (len != sizeof(struct_message)) return;

  struct_message incoming;
  memcpy(&incoming, data, sizeof(incoming));
  if (!incoming.ack) return;

  String senderMac = "";
  for (int i = 0; i < 6; i++) {
    if (mac_addr[i] < 16) senderMac += "0";
    senderMac += String(mac_addr[i], HEX);
    if (i < 5) senderMac += ":";
  }
  senderMac.toUpperCase();

  Serial.println("ACK received from: " + senderMac);
  Serial.println("Confirmed: " + String(incoming.status));

  int pagerNum = -1;
  for (int i = 0; i < pagerCount; i++) {
    if (memcmp(pagers[i].mac, mac_addr, 6) == 0) {
      pagerNum = i + 1;
      break;
    }
  }

  String statusStr = String(incoming.status);
  String ackCmd = statusStr;
  if (statusStr.startsWith("ACK:")) {
    int firstColon = statusStr.indexOf(':', 4);
    if (firstColon > 0) ackCmd = statusStr.substring(firstColon + 1);
  }

  // Heartbeat ACKs are too noisy and can destabilize BLE if forwarded/logged
  // continuously. Keep heartbeat handling internal only.
  if (ackCmd == "HEARTBEAT") {
    return;
  }

  if (pagerNum > 0) {
    logACKReceived(pagerNum - 1, ackCmd.c_str());
  }

  String bleMsg;
  if (pagerNum > 0) {
    bleMsg = "SLAVE_ACK: Pager #" + String(pagerNum) +
             " [" + String(pagers[pagerNum - 1].serialNum) + "]" +
             " (" + senderMac + ") confirmed: " + ackCmd;
  } else {
    bleMsg = "SLAVE_ACK: " + senderMac + " confirmed: " + ackCmd;
  }

  sendBLEResponse(bleMsg);
}

// ==================== SEND FUNCTIONS ====================

void sendAlertToMac(uint8_t *targetMac) {
  if (!esp_now_is_peer_exist(targetMac)) {
    esp_now_peer_info_t peerInfo = {};
    memcpy(peerInfo.peer_addr, targetMac, 6);
    peerInfo.channel = 1;
    peerInfo.encrypt = false;
    esp_now_add_peer(&peerInfo);
  }

  sendBLEResponse("Alerting MAC: " + macToString(targetMac));

  memset(&outgoingMessage, 0, sizeof(outgoingMessage));
  strcpy(outgoingMessage.command, "ALERT");
  outgoingMessage.duration = 5;
  outgoingMessage.ack = false;

  esp_err_t result = esp_now_send(targetMac, (uint8_t *)&outgoingMessage, sizeof(outgoingMessage));
  Serial.print("Send result: ");
  Serial.println(esp_err_to_name(result));

  for (int i = 0; i < pagerCount; i++) {
    if (memcmp(pagers[i].mac, targetMac, 6) == 0) {
      logCommandSent(i, "ALERT");
      break;
    }
  }

  if (result == ESP_OK) sendBLEResponse("OK: Alert sent");
  else sendBLEResponse("ERROR: Send failed - check Serial Monitor");
}

void sendStatusToMac(uint8_t *targetMac, String statusText) {
  if (!esp_now_is_peer_exist(targetMac)) {
    esp_now_peer_info_t peerInfo = {};
    memcpy(peerInfo.peer_addr, targetMac, 6);
    peerInfo.channel = 1;
    peerInfo.encrypt = false;
    esp_now_add_peer(&peerInfo);
  }

  sendBLEResponse("Sending status [" + statusText + "] to: " + macToString(targetMac));

  memset(&outgoingMessage, 0, sizeof(outgoingMessage));
  strcpy(outgoingMessage.command, "STATUS");
  strncpy(outgoingMessage.status, statusText.c_str(), sizeof(outgoingMessage.status) - 1);
  outgoingMessage.status[sizeof(outgoingMessage.status) - 1] = '\0';
  outgoingMessage.duration = 0;
  outgoingMessage.ack = false;

  esp_err_t result = esp_now_send(targetMac, (uint8_t *)&outgoingMessage, sizeof(outgoingMessage));
  Serial.print("Send result: ");
  Serial.println(esp_err_to_name(result));

  String logEntry = "STATUS:" + statusText;
  for (int i = 0; i < pagerCount; i++) {
    if (memcmp(pagers[i].mac, targetMac, 6) == 0) {
      logCommandSent(i, logEntry.c_str());
      break;
    }
  }

  if (result == ESP_OK) sendBLEResponse("OK: Status sent");
  else sendBLEResponse("ERROR: Send failed - check Serial Monitor");
}

void sendAlertToPager(int pagerNumber) {
  if (pagerNumber < 1 || pagerNumber > pagerCount) {
    sendBLEResponse("ERROR: Pager #" + String(pagerNumber) + " not found");
    return;
  }
  if (!pagers[pagerNumber - 1].active) {
    sendBLEResponse("ERROR: Pager #" + String(pagerNumber) + " is inactive");
    return;
  }

  uint8_t *targetMac = pagers[pagerNumber - 1].mac;
  sendBLEResponse("Alerting Pager #" + String(pagerNumber) + " (" + macToString(targetMac) + ")");
  sendAlertToMac(targetMac);
}

// ==================== HEARTBEAT ====================

void sendHeartbeat() {
  memset(&outgoingMessage, 0, sizeof(outgoingMessage));
  strcpy(outgoingMessage.command, "HEARTBEAT");
  outgoingMessage.duration = 0;
  outgoingMessage.ack = false;

  int sentCount = 0;
  for (int i = 0; i < pagerCount; i++) {
    if (!pagers[i].active) continue;
    esp_err_t result = esp_now_send(pagers[i].mac, (uint8_t *)&outgoingMessage, sizeof(outgoingMessage));
    if (result == ESP_OK) sentCount++;
  }

  Serial.println("Heartbeat sent to " + String(sentCount) + " pagers");
}

// ==================== COMMAND PROCESSING ====================

void processSetupCommand(String command) {
  command.trim();
  String originalCommand = command;
  command.toUpperCase();

  if (command.startsWith("ADD:")) {
    String macStr = command.substring(4);
    uint8_t mac[6];
    if (parseMacAddress(macStr, mac)) {
      int pagerNum = addPager(mac);
      if (pagerNum > 0) {
        sendBLEResponse("OK: Pager added as #" + String(pagerNum) + " [" + String(pagers[pagerNum - 1].serialNum) + "]");
      } else {
        sendBLEResponse("ERROR: Pager memory full");
      }
    } else {
      sendBLEResponse("ERROR: Invalid MAC format. Use AA:BB:CC:DD:EE:FF");
    }
  } else if (command == "LIST") {
    listPagers();
  } else if (command.startsWith("DELETE:")) {
    int pagerNum = command.substring(7).toInt();
    if (deletePager(pagerNum)) {
      sendBLEResponse("OK: Pager #" + String(pagerNum) + " deleted");
    } else {
      sendBLEResponse("ERROR: Invalid pager number");
    }
  } else if (command == "CLEAR") {
    clearAllPagers();
  } else {
    sendBLEResponse("ERROR: Unknown command: " + originalCommand);
  }
}

void processPagingCommand(String command) {
  command.trim();

  String cmdUpper = command;
  cmdUpper.toUpperCase();

  if (cmdUpper.startsWith("STATUS:")) {
    String rest = command.substring(7);

    bool looksLikeMacPrefix =
      rest.length() >= 19 &&
      rest.charAt(2)  == ':' &&
      rest.charAt(5)  == ':' &&
      rest.charAt(8)  == ':' &&
      rest.charAt(11) == ':' &&
      rest.charAt(14) == ':' &&
      rest.charAt(17) == ':';

    if (looksLikeMacPrefix) {
      String macPart  = rest.substring(0, 17);
      String textPart = rest.substring(18);
      textPart.trim();

      if (textPart.length() == 0) {
        sendBLEResponse("ERROR: STATUS text is empty");
        return;
      }

      uint8_t targetMac[6];
      if (!parseMacAddress(macPart, targetMac)) {
        sendBLEResponse("ERROR: Invalid MAC in STATUS command");
        return;
      }

      sendStatusToMac(targetMac, textPart);
      return;
    }

    int colonPos = rest.indexOf(':');
    if (colonPos <= 0) {
      sendBLEResponse("ERROR: STATUS format: STATUS:<NUM>:<TEXT> or STATUS:<MAC>:<TEXT>");
      return;
    }

    String numPart = rest.substring(0, colonPos);
    String textPart = rest.substring(colonPos + 1);
    numPart.trim();
    textPart.trim();

    if (!isDigitsOnly(numPart)) {
      sendBLEResponse("ERROR: STATUS target must be pager number or MAC");
      return;
    }

    if (textPart.length() == 0) {
      sendBLEResponse("ERROR: STATUS text is empty");
      return;
    }

    int pagerNum = numPart.toInt();
    if (pagerNum < 1 || pagerNum > pagerCount || !pagers[pagerNum - 1].active) {
      sendBLEResponse("ERROR: Pager #" + String(pagerNum) + " not found or inactive");
      return;
    }

    sendStatusToMac(pagers[pagerNum - 1].mac, textPart);
    return;
  }

  if (command.indexOf(':') > 0 || (command.length() == 12 && isHexString(command))) {
    uint8_t targetMac[6];
    if (parseMacAddress(command, targetMac)) {
      sendAlertToMac(targetMac);
    } else {
      sendBLEResponse("ERROR: Invalid MAC address format");
    }
  } else {
    int pagerNum = command.toInt();
    if (pagerNum > 0) sendAlertToPager(pagerNum);
    else sendBLEResponse("ERROR: Invalid command (send MAC address or pager number)");
  }
}

// ==================== SETUP ====================

void setup() {
  Serial.begin(115200);

  pinMode(SETUP_SWITCH_PIN, INPUT_PULLUP);
  pinMode(STATUS_LED_PIN, OUTPUT);
  digitalWrite(STATUS_LED_PIN, LOW);

  if (!SPIFFS.begin(true)) {
    Serial.println("ERROR: SPIFFS mount failed");
  } else {
    Serial.println("SPIFFS mounted OK - total: " + String(SPIFFS.totalBytes()) +
                   " used: " + String(SPIFFS.usedBytes()));
  }

  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  delay(100);
  esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE);

  Serial.print("Master MAC: ");
  Serial.println(WiFi.macAddress());
  Serial.println("WiFi Channel: 1");

  if (esp_now_init() != ESP_OK) {
    Serial.println("ERROR: ESP-NOW init failed");
    return;
  }
  esp_now_register_send_cb(OnDataSent);
  esp_now_register_recv_cb(OnDataRecv);

  loadBleConfig();

  BLEDevice::init(bleDeviceName.c_str());
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);
  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharacteristic->addDescriptor(new BLE2902());
  pCharacteristic->setCallbacks(new MyCallbacks());

  pService->start();
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("BLE Started - Device Name: " + bleDeviceName);
  Serial.println("BLE Auth Code (last 4 MAC digits): " + getMasterAuthCode());

  loadPagersFromFlash();

  for (int i = 0; i < pagerCount; i++) {
    if (!pagers[i].active) continue;
    esp_now_peer_info_t peerInfo = {};
    memcpy(peerInfo.peer_addr, pagers[i].mac, 6);
    peerInfo.channel = 1;
    peerInfo.encrypt = false;
    esp_now_add_peer(&peerInfo);
    Serial.println("Re-added peer: " + macToString(pagers[i].mac));
  }

  writeJSON();
  writeCSV();

  Serial.println("\n=== MASTER ESP32 READY (v7.2 merged) ===");
  Serial.println("Paging: Send MAC address or pager number");
  Serial.println("Heartbeat: Sending every 5 seconds");
  Serial.println("Setup commands:");
  Serial.println("  ADD:AA:BB:CC:DD:EE:FF");
  Serial.println("  LIST");
  Serial.println("  DELETE:3");
  Serial.println("  CLEAR");
  Serial.println("Status command:");
  Serial.println("  STATUS:<MAC>:<TEXT>");
  Serial.println("  STATUS:<NUM>:<TEXT>");
  Serial.println("Report commands:");
  Serial.println("  GET_REPORT");
  Serial.println("  /master_excel");
  Serial.println("  SET_SERIAL:<NUM>:<LABEL>");
  Serial.println("Security commands:");
  Serial.println("  AUTH:<LAST4MAC>");
  Serial.println("  SET_BLE_NAME:<NEW_NAME>");
  Serial.println("Serial Monitor: type \"/master_excel\" to print CSV");
  Serial.println("========================================\n");

  listPagers();
  lastHeartbeatTime = millis();
}

// ==================== LOOP ====================

void loop() {
  if (Serial.available()) {
    // Works with Serial Monitor line ending = None/CR/LF.
    String serialInput = Serial.readString();
    serialInput.trim();
    if (serialInput.equalsIgnoreCase("/master_excel") ||
        serialInput.equalsIgnoreCase("master_excel") ||
        serialInput.equalsIgnoreCase("excel") ||
        serialInput.equalsIgnoreCase("master")) {
      printCSVToSerial();
    }
  }

  if (millis() - lastHeartbeatTime >= HEARTBEAT_INTERVAL) {
    sendHeartbeat();
    lastHeartbeatTime = millis();
  }

  if (deviceConnected &&
      !clientAuthenticated &&
      pendingDisconnectAt == 0 &&
      millis() - bleConnectedAt >= AUTH_TIMEOUT_MS) {
    sendBLEResponse("ERROR: Authorization timeout");
    scheduleBleDisconnect("BLE auth timeout");
  }

  if (pendingDisconnectAt != 0 && millis() >= pendingDisconnectAt) {
    pendingDisconnectAt = 0;
    if (deviceConnected) {
      pServer->disconnect(pServer->getConnId());
    }
  }

  if (pendingRestartAt != 0 && millis() >= pendingRestartAt) {
    pendingRestartAt = 0;
    Serial.println("Restarting to apply BLE name change");
    delay(200);
    ESP.restart();
  }

  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    Serial.println("Started advertising");
    oldDeviceConnected = deviceConnected;
  }

  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }

  int switchReading = digitalRead(SETUP_SWITCH_PIN);
  if (switchReading != lastSwitchState) lastDebounceTime = millis();

  if ((millis() - lastDebounceTime) > debounceDelay) {
    if (switchReading == LOW && lastSwitchState == HIGH) {
      setupMode = !setupMode;
      if (setupMode) {
        Serial.println("\n*** SETUP MODE ACTIVATED ***");
        digitalWrite(STATUS_LED_PIN, HIGH);
      } else {
        Serial.println("\n*** PAGING MODE ACTIVATED ***");
        digitalWrite(STATUS_LED_PIN, LOW);
      }
    }
  }
  lastSwitchState = switchReading;

  if (setupMode) {
    if (millis() - lastBlinkTime >= 250) {
      ledState = !ledState;
      digitalWrite(STATUS_LED_PIN, ledState);
      lastBlinkTime = millis();
    }
  }

  delay(10);
}
