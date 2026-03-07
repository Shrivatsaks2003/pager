// SLAVE ESP32 - Restaurant Pager System v3.1 (Matched with master v7.2)

#include <esp_now.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <Preferences.h>
#include <Adafruit_NeoPixel.h>
#include <ctype.h>
#include <string.h>

// ---------------- HARDWARE ----------------
#define ONBOARD_LED 2
#define LED_PIN 27
#define NUM_LEDS 8
#define BUZZER_PIN 26
#define VIBRATION_PIN 25

Adafruit_NeoPixel strip(NUM_LEDS, LED_PIN, NEO_GRB + NEO_KHZ800);

// ---------------- STRUCT (must match master exactly) ----------------
typedef struct struct_message {
  char command[32];
  int duration;
  char status[64];
  bool ack;
} struct_message;

struct_message incomingData;
struct_message ackMessage;

// ---------------- MASTER MAC ----------------
uint8_t masterMac[6] = {0, 0, 0, 0, 0, 0};
bool masterMacKnown = false;
Preferences preferences;

// this pager's own serial number, stored in Preferences
char mySerial[16] = "UNKN";

// ---------------- RANGE MONITOR ----------------
unsigned long lastHeartbeatTime = 0;
const unsigned long OUT_OF_RANGE_TIMEOUT = 30000;
bool outOfRange = false;
bool heartbeatReceivedOnce = false;

// ======================================================
// Serial number persistence
// ======================================================
void loadMySerial() {
  preferences.begin("pager_cfg", true);
  String sn = preferences.getString("serial", "");
  preferences.end();

  if (sn.length() > 0) {
    strncpy(mySerial, sn.c_str(), sizeof(mySerial) - 1);
    mySerial[sizeof(mySerial) - 1] = '\0';
  }

  Serial.println("My Serial: " + String(mySerial));
}

void saveMySerial(const char *sn) {
  strncpy(mySerial, sn, sizeof(mySerial) - 1);
  mySerial[sizeof(mySerial) - 1] = '\0';

  preferences.begin("pager_cfg", false);
  preferences.putString("serial", mySerial);
  preferences.end();

  Serial.println("Serial saved: " + String(mySerial));
}

// ======================================================
// Master MAC persistence
// ======================================================
void saveMasterMac() {
  preferences.begin("pager_cfg", false);
  for (int i = 0; i < 6; i++) {
    preferences.putUChar(("mm" + String(i)).c_str(), masterMac[i]);
  }
  preferences.putBool("mm_known", true);
  preferences.end();
  Serial.println("Master MAC saved to flash");
}

bool loadMasterMac() {
  preferences.begin("pager_cfg", true);
  bool known = preferences.getBool("mm_known", false);
  if (known) {
    for (int i = 0; i < 6; i++) {
      masterMac[i] = preferences.getUChar(("mm" + String(i)).c_str(), 0x00);
    }
  }
  preferences.end();
  return known;
}

void ensureMasterPeer() {
  if (!masterMacKnown) return;

  if (!esp_now_is_peer_exist(masterMac)) {
    esp_now_peer_info_t peerInfo = {};
    memcpy(peerInfo.peer_addr, masterMac, 6);
    peerInfo.channel = 1;
    peerInfo.encrypt = false;
    esp_now_add_peer(&peerInfo);
  }
}

void learnMasterMac(const uint8_t *senderMac) {
  if (masterMacKnown) return;

  memcpy(masterMac, senderMac, 6);
  masterMacKnown = true;
  ensureMasterPeer();

  Serial.print("Master MAC learned: ");
  for (int i = 0; i < 6; i++) {
    Serial.printf("%02X", masterMac[i]);
    if (i < 5) Serial.print(":");
  }
  Serial.println();

  saveMasterMac();
}

// ======================================================
// ACK back to master
// status format: "ACK:<SERIAL>:<CMD>"
// ======================================================
void sendAckToMaster(const char *originalCommand) {
  if (!masterMacKnown) {
    Serial.println("ACK skipped - master MAC not yet known");
    return;
  }

  memset(&ackMessage, 0, sizeof(ackMessage));
  strncpy(ackMessage.command, "ACK", sizeof(ackMessage.command) - 1);

  char ackStatus[64];
  snprintf(ackStatus, sizeof(ackStatus), "ACK:%s:%s", mySerial, originalCommand);
  strncpy(ackMessage.status, ackStatus, sizeof(ackMessage.status) - 1);

  ackMessage.duration = 0;
  ackMessage.ack = true;

  ensureMasterPeer();

  esp_err_t result = esp_now_send(masterMac, (uint8_t *)&ackMessage, sizeof(ackMessage));
  Serial.print("ACK sent [");
  Serial.print(ackStatus);
  Serial.print("] - ");
  Serial.println(result == ESP_OK ? "OK" : esp_err_to_name(result));
}

// ======================================================
// LED/Alert helpers
// ======================================================
void setAllColor(uint8_t r, uint8_t g, uint8_t b) {
  for (int i = 0; i < NUM_LEDS; i++) {
    strip.setPixelColor(i, strip.Color(r, g, b));
  }
  strip.show();
}

void orderReadyAlert(int duration) {
  for (int i = 0; i < duration; i++) {
    setAllColor(255, 0, 0);
    tone(BUZZER_PIN, 2000);
    digitalWrite(VIBRATION_PIN, HIGH);
    delay(300);

    setAllColor(0, 255, 0);
    tone(BUZZER_PIN, 2500);
    delay(300);

    setAllColor(0, 0, 255);
    tone(BUZZER_PIN, 3000);
    delay(300);

    noTone(BUZZER_PIN);
    digitalWrite(VIBRATION_PIN, LOW);
    setAllColor(0, 0, 0);
    delay(300);
  }
}

void outOfRangeAlert() {
  setAllColor(255, 0, 0);
  tone(BUZZER_PIN, 1000);
  delay(800);
  noTone(BUZZER_PIN);
  delay(800);
}

// ======================================================
// STATUS handling
// ======================================================
void handleStatusAlert(const char *statusText) {
  String st = String(statusText);
  st.trim();
  st.toUpperCase();

  if (st == "A") st = "PREPARING";
  else if (st == "B") st = "READY";
  else if (st == "C") st = "CANCELLED";
  else if (st == "D") st = "READY";
  else if (st == "E") st = "PREPARING";

  if (st == "PREPARING") {
    for (int i = 0; i < 3; i++) {
      setAllColor(255, 165, 0);
      tone(BUZZER_PIN, 1200);
      delay(300);
      setAllColor(0, 0, 0);
      noTone(BUZZER_PIN);
      delay(200);
    }
  } else if (st == "READY") {
    for (int i = 0; i < 5; i++) {
      setAllColor(0, 255, 0);
      tone(BUZZER_PIN, 2500);
      digitalWrite(VIBRATION_PIN, HIGH);
      delay(250);
      setAllColor(0, 0, 0);
      noTone(BUZZER_PIN);
      digitalWrite(VIBRATION_PIN, LOW);
      delay(150);
    }
  } else if (st == "CANCELLED") {
    for (int i = 0; i < 4; i++) {
      setAllColor(255, 0, 0);
      tone(BUZZER_PIN, 500);
      delay(400);
      setAllColor(0, 0, 0);
      noTone(BUZZER_PIN);
      delay(200);
    }
  } else {
    for (int i = 0; i < 2; i++) {
      setAllColor(255, 255, 255);
      tone(BUZZER_PIN, 1800);
      delay(300);
      setAllColor(0, 0, 0);
      noTone(BUZZER_PIN);
      delay(200);
    }
  }
}

// ---------------- RECEIVE CALLBACK ----------------
void onDataRecv(const uint8_t *mac, const uint8_t *incomingDataRaw, int len) {
  if (len != (int)sizeof(struct_message)) {
    Serial.print("Invalid packet size: ");
    Serial.println(len);
    return;
  }

  memcpy(&incomingData, incomingDataRaw, sizeof(incomingData));

  if (incomingData.ack) {
    Serial.println("Received ACK packet (ignored on slave)");
    return;
  }

  learnMasterMac(mac);

  Serial.println("Message Received");
  Serial.print("Command: ");
  Serial.println(incomingData.command);

  if (strcmp(incomingData.command, "ALERT") == 0) {
    orderReadyAlert(incomingData.duration);

    for (int i = 0; i < 3; i++) {
      digitalWrite(ONBOARD_LED, HIGH);
      delay(200);
      digitalWrite(ONBOARD_LED, LOW);
      delay(200);
    }

    sendAckToMaster("ALERT");
  }
  else if (strcmp(incomingData.command, "HEARTBEAT") == 0) {
    Serial.println("Heartbeat received");
    lastHeartbeatTime = millis();
    heartbeatReceivedOnce = true;
    outOfRange = false;

    sendAckToMaster("HEARTBEAT");
  }
  else if (strcmp(incomingData.command, "STATUS") == 0) {
    Serial.print("Status received: ");
    Serial.println(incomingData.status);

    String statusStr = String(incomingData.status);

    if (statusStr.startsWith("SET_SERIAL:")) {
      String label = statusStr.substring(11);
      label.trim();
      if (label.length() > 0) {
        saveMySerial(label.c_str());
      }
      sendAckToMaster("SET_SERIAL");
    } else {
      handleStatusAlert(incomingData.status);
      String ackCmd = "STATUS:" + statusStr;
      sendAckToMaster(ackCmd.c_str());
    }
  }
  else {
    Serial.println("Unknown command");
  }
}

// ---------------- SETUP ----------------
void setup() {
  Serial.begin(115200);

  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(VIBRATION_PIN, OUTPUT);
  pinMode(ONBOARD_LED, OUTPUT);
  digitalWrite(ONBOARD_LED, LOW);
  digitalWrite(VIBRATION_PIN, LOW);

  strip.begin();
  strip.show();

  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  delay(100);
  esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE);

  if (esp_now_init() != ESP_OK) {
    Serial.println("ESP-NOW Init Failed");
    return;
  }

  esp_now_register_recv_cb(onDataRecv);

  Serial.print("Pager MAC: ");
  Serial.println(WiFi.macAddress());

  loadMySerial();

  bool restored = loadMasterMac();
  if (restored) {
    masterMacKnown = true;
    Serial.print("Restored master MAC from flash: ");
    for (int i = 0; i < 6; i++) {
      Serial.printf("%02X", masterMac[i]);
      if (i < 5) Serial.print(":");
    }
    Serial.println();

    ensureMasterPeer();
    Serial.println("Master re-registered as ESP-NOW peer");
  } else {
    Serial.println("No master MAC in flash - will learn on first contact");
  }

  lastHeartbeatTime = millis();
  Serial.println("PAGER READY | Serial: " + String(mySerial));
}

// ---------------- LOOP ----------------
void loop() {
  unsigned long currentMillis = millis();

  if (heartbeatReceivedOnce &&
      !outOfRange &&
      currentMillis - lastHeartbeatTime > OUT_OF_RANGE_TIMEOUT) {
    outOfRange = true;
    Serial.println("OUT OF RANGE!");
  }

  if (outOfRange) {
    outOfRangeAlert();
  }

  delay(10);
}
