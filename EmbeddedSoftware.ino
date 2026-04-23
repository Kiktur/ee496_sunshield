// --- CORE LIBRARIES ---
#include <Arduino.h>
#include "driver/rtc_io.h"

// --- SCREEN LIBRARIES ---
#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>

// --- BLUETOOTH LIBRARIES ---
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLEClient.h>
#include "BLEScan.h"
#include <BLE2902.h>

// --- HARDWARE PINS ---
#define BUTTON    4 
#define MOTOR     17
#define genSen    6          
#define sunSen    5           
#define battery   0           
#define TFT_CS    20 
#define TFT_RST   19
#define TFT_DC    7 

// --- DEEP SLEEP CONSTANTS ---
#define uS_TO_S_FACTOR 1000000ULL
#define TIME_TO_SLEEP  30 

// --- RTC MEMORY (Survives Deep Sleep) ---
RTC_DATA_ATTR float counter = 200.0; 
RTC_DATA_ATTR int spf = 30; 
RTC_DATA_ATTR int skinType = 1; 

// --- GLOBAL OBJECTS & STATES ---
Adafruit_ST7789 tft = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_RST);
bool deviceConnected = false;
bool motorMode = false; 
bool screenMode = false;

// --- TIMING VARIABLES ---
unsigned long previousMillis = 0;
const long interval = 1000; // 1 second interval
int awakeTime = 0; 

// --- ALGORITHM DATA ---
int limits[][5] = { 
  {120, 60, 40, 20, 10},
  {120, 80, 60, 30, 20},
  {180,100, 80, 40, 30},
  {180,120,100, 60, 40},
  {200,140,120, 80, 60},
  {200,160,140,100, 80}
};

// --- BLE UUIDS ---
#define SERVICE_UUID               "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX_SPF "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_RX_SKN "6E400003-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_TX_UV  "6E400004-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_TX_MIN "6E400005-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_TX_BAT "6E400007-B5A3-F393-E0A9-E50E24DCCA9E"

// --- BLE POINTERS ---
BLEServer *pServer = NULL;
BLECharacteristic *pTxUV;
BLECharacteristic *pTxMinutes;
BLECharacteristic *pTxBattery;

// ==========================================
//          BLE CALLBACKS
// ==========================================
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) { 
      deviceConnected = true; 
    }
    void onDisconnect(BLEServer* pServer) { 
      deviceConnected = false; 
      pServer->getAdvertising()->start(); 
    }
};

class SpfCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) override {
      String data = pCharacteristic->getValue();
      if (data.length() > 0) spf = data.toInt(); 
    }
};

class SkinCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) override {
      String data = pCharacteristic->getValue();
      if (data.length() > 0) skinType = data.toInt(); 
    }
};

void bluetoothSetup() {
  BLEDevice::init("ESP32-C6");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService *pMain = pServer->createService(SERVICE_UUID);
  
  pTxUV = pMain->createCharacteristic(CHARACTERISTIC_UUID_TX_UV, BLECharacteristic::PROPERTY_NOTIFY);
  pTxMinutes = pMain->createCharacteristic(CHARACTERISTIC_UUID_TX_MIN, BLECharacteristic::PROPERTY_NOTIFY);
  pTxBattery = pMain->createCharacteristic(CHARACTERISTIC_UUID_TX_BAT, BLECharacteristic::PROPERTY_NOTIFY);

  BLECharacteristic *pRxSpf = pMain->createCharacteristic(CHARACTERISTIC_UUID_RX_SPF, BLECharacteristic::PROPERTY_WRITE);
  pRxSpf->setCallbacks(new SpfCallback());
  BLECharacteristic *pRxSkin = pMain->createCharacteristic(CHARACTERISTIC_UUID_RX_SKN, BLECharacteristic::PROPERTY_WRITE);
  pRxSkin->setCallbacks(new SkinCallback());

  pMain->start();
  pServer->getAdvertising()->start();
}

// ==========================================
//          HARDWARE & SENSORS
// ==========================================
void pinSetup() { 
  pinMode(genSen, INPUT);
  pinMode(sunSen, INPUT);
  pinMode(BUTTON, INPUT_PULLDOWN); 
  rtc_gpio_pullup_dis(BUTTON);
  rtc_gpio_pulldown_en(BUTTON);
  pinMode(MOTOR, OUTPUT);
  digitalWrite(MOTOR, LOW); 
}

void screenSetup() {
  tft.init(240, 240); 
  tft.setRotation(2); 
  tft.setTextColor(ST77XX_WHITE, ST77XX_BLUE); 
  tft.setTextSize(2); 

  if (screenMode) {
    tft.fillScreen(ST77XX_BLUE); 
  } else {
    tft.fillScreen(ST77XX_BLACK); 
  }
}

float readSensor(int sensor) {
  float index = analogRead(sensor) * (3.3 / 4095.0) / 0.1;
  float calibrated = index * 1.33333;
  return calibrated;
}

uint8_t getBattery() {
  float percentage = analogReadMilliVolts(battery) * 2.0 / 37;
  return percentage;
}

int getColumn(float index) {
  if (index < 3.0) return 0;       
  if (index >= 3.0 && index < 6.0) return 1;  
  if (index >= 6.0 && index < 8.0) return 2;  
  if (index >= 8.0 && index < 11.0) return 3; 
  return 4;                          
}

void deepSleep(int time) {  
  esp_sleep_enable_ext1_wakeup(1ULL << BUTTON, ESP_EXT1_WAKEUP_ANY_HIGH);
  esp_sleep_enable_timer_wakeup(time * uS_TO_S_FACTOR);
  
  Serial.flush();
  tft.fillScreen(ST77XX_BLACK); 
  esp_deep_sleep_start();
}

// ==========================================
//          SETUP
// ==========================================
void setup() {
  Serial.begin(115200);

  esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  if(cause == ESP_SLEEP_WAKEUP_TIMER) {
      screenMode = false;
    } else {
      screenMode = true; 
    }

  pinSetup();
  bluetoothSetup();
  screenSetup(); 
}

void debug() {
  Serial.println("general: " + String(general));
  Serial.println("sunscreen: " + String(sunscreen));
  Serial.println("spf: " + String(spf));
  Serial.println("skinType: " + String(skinType));
  Serial.println("deviceConnected: " + String(deviceConnected));
  Serial.println("screenMode: " + String(screenMode));
  Serial.println("motorMode: " + String(motorMode));
  Serial.println("minutes: " + String(minutes));
  Serial.println("seconds: " + String(seconds));
  Serial.println("awakeTime: " + String(awakeTime));
}

// ==========================================
//          MAIN SUPER LOOP
// ==========================================
void loop() {
  unsigned long currentMillis = millis();

  // Execute this block exactly once per second
  if (currentMillis - previousMillis >= interval) {
    previousMillis = currentMillis;

    float general = readSensor(genSen);
    float sunscreen = readSensor(sunSen);
    uint8_t percent = getBattery();
    
    float matrixVal = limits[skinType - 1][getColumn(general)] * ( (float)spf / 30.0 );
    matrixVal = max((float)1.0, matrixVal);
    float ratio = 200.0 / (matrixVal * 60);

    if (general > 1){
      counter -= ratio;
    }
    
    if (general - sunscreen < 0.5 && general > 3) {
      counter = 0.0;
    }

    if (counter <= 0 && !motorMode) {
      digitalWrite(MOTOR, HIGH);
      motorMode = true;
      if (!screenMode) {
          tft.fillScreen(ST77XX_BLUE); // Visually turn the screen back on!
          screenMode = true;
      }
    }

    if (digitalRead(BUTTON) == HIGH) {
      counter = 200.0;
      digitalWrite(MOTOR, LOW);
      motorMode = false;
      awakeTime = 0;
    }
    
    float secondsLeft = (counter / 200.0) * (matrixVal * 60.0);
    int minutes = secondsLeft / 60;
    int seconds = (int)secondsLeft % 60;
    if (screenMode) {
      tft.setCursor(0, 50);
      if (motorMode) {
        tft.print("Reapply sunscreen!");
      }
      else{
        tft.printf("Time: %02d:%02d              ", minutes, seconds);
      }
      tft.setCursor(0, 100);
      tft.print("UV: " + String(general, 1) + "  ");
      tft.setCursor(0, 150);
      tft.print("Battery: " + String(percent) + "%  ");
    }

    if (deviceConnected) {
        pTxBattery->setValue(&percent, 1);
        pTxBattery->notify();
        pTxUV->setValue((uint8_t*)&general, 4); 
        pTxUV->notify();
        pTxMinutes->setValue((uint8_t*)&counter, 4); 
        pTxMinutes->notify();
    }
    
    awakeTime++;
    if (awakeTime >= 10 && !deviceConnected && !motorMode) {
      int sleepTime = TIME_TO_SLEEP; 
      if (secondsLeft > 0 && secondsLeft < TIME_TO_SLEEP) {
          sleepTime = (int)secondsLeft;
      }
      screenMode = false;
      counter -= ratio * sleepTime;
      deepSleep(sleepTime);
    }
  }
}
