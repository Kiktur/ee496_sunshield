// --- CORE LIBRARIES ---
#include <Arduino.h>
#include "driver/rtc_io.h"
#include <LittleFS.h>
#include <Preferences.h>
#include <sys/time.h>
#include <time.h>

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
#define BUTTON    GPIO_NUM_4
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
RTC_DATA_ATTR float currentTime = 0;

// --- GLOBAL OBJECTS & FLAGS ---
Adafruit_ST7789 tft = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_RST);
Preferences preferences;
TaskHandle_t MainTask;
bool deviceConnected = false;
bool isSyncing = false;
bool triggerAutoSync = false; // THE NEW AUTO-SYNC FLAG
int awakeTime = 0; 
bool motorMode = false; 
bool screenMode = false;

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
#define SERVICE_UUID                "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX_SPF  "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_RX_SKN  "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX_DAT  "6E400004-B5A3-F393-E0A9-E50E24DCCA9E"  
#define CHARACTERISTIC_UUID_TX_UV   "6E400005-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_TX_MIN  "6E400006-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_TX_BAT  "6E400007-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_TX_SYNC "6E400008-B5A3-F393-E0A9-E50E24DCCA9E" 

// --- BLE POINTERS ---
BLEServer *pServer = NULL;
BLECharacteristic *pTxUV;
BLECharacteristic *pTxMinutes;
BLECharacteristic *pTxBattery;
BLECharacteristic *pTxSync;

// ==========================================
//          DELTA SYNC FUNCTION
// ==========================================
void syncHistoricalData() {
  isSyncing = true;
  File file = LittleFS.open("/uv_datalog.csv", FILE_READ);
  if (!file) {
    pTxSync->setValue("NO_DATA");
    pTxSync->notify();
    isSyncing = false;
    return;
  }

  preferences.begin("uvSensors", false); 
  size_t lastPosition = preferences.getUInt("sync_ptr", 0); 
  if (lastPosition > file.size()) lastPosition = 0;

  file.seek(lastPosition);
  pTxSync->setValue("SYNC_START");
  pTxSync->notify();
  vTaskDelay(50 / portTICK_PERIOD_MS);

  while (file.available()) {
    if (!deviceConnected) break; // Abort if phone walks away
    String line = file.readStringUntil('\n');
    if (line.length() > 0) {
      pTxSync->setValue(line.c_str());
      pTxSync->notify();
      vTaskDelay(30 / portTICK_PERIOD_MS); 
    }
  }

  size_t newPosition = file.position();
  preferences.putUInt("sync_ptr", newPosition);
  preferences.end(); 

  pTxSync->setValue("SYNC_END");
  pTxSync->notify();
  file.close();
  isSyncing = false;
}

// ==========================================
//          BLE CALLBACKS
// ==========================================
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) { 
      deviceConnected = true; 
      triggerAutoSync = true; // Tell the main loop to dump the CSV!
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

class DateCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) override {
      String appData = pCharacteristic->getValue();
      if (appData.startsWith("TIME:")) {
        currentTime = appData.substring(5).toInt(); // Updates our custom clock!
      } else if (appData == "WIPE_DATA") {
        LittleFS.remove("/uv_datalog.csv");
        preferences.begin("uvSensors", false);
        preferences.putUInt("sync_ptr", 0); 
        preferences.end();
      }
    }
};

void bluetoothSetup() {
  BLEDevice::init("SunShield");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService *pMain = pServer->createService(SERVICE_UUID);
  
  pTxUV = pMain->createCharacteristic(CHARACTERISTIC_UUID_TX_UV, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pTxUV->addDescriptor(new BLE2902());
  pTxMinutes = pMain->createCharacteristic(CHARACTERISTIC_UUID_TX_MIN, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pTxMinutes->addDescriptor(new BLE2902());
  pTxBattery = pMain->createCharacteristic(CHARACTERISTIC_UUID_TX_BAT, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pTxBattery->addDescriptor(new BLE2902());
  pTxSync = pMain->createCharacteristic(CHARACTERISTIC_UUID_TX_SYNC, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pTxSync->addDescriptor(new BLE2902());

  BLECharacteristic *pRxSpf = pMain->createCharacteristic(CHARACTERISTIC_UUID_RX_SPF, BLECharacteristic::PROPERTY_WRITE);
  pRxSpf->setCallbacks(new SpfCallback());
  BLECharacteristic *pRxSkin = pMain->createCharacteristic(CHARACTERISTIC_UUID_RX_SKN, BLECharacteristic::PROPERTY_WRITE);
  pRxSkin->setCallbacks(new SkinCallback());
  BLECharacteristic *pRxDat = pMain->createCharacteristic(CHARACTERISTIC_UUID_RX_DAT, BLECharacteristic::PROPERTY_WRITE);
  pRxDat->setCallbacks(new DateCallback());

  pMain->start();
  pServer->getAdvertising()->start();
}

// ==========================================
//          HARDWARE & LOGGING
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
  float calibrated = (index * 12.5) - 17.0;
  if (calibrated < 0.0) {
    calibrated = 0.0;
  }
}

uint8_t getBattery() {
  float percentage = analogReadMilliVolts(battery) * 2.0;
  float calibrated = (3.7 - percentage) / 37;
  return percentage;
}

int getColumn(float index) {
  if (index < 3.0) return 0;       
  if (index >= 3.0 && index < 6.0) return 1;  
  if (index >= 6.0 && index < 8.0) return 2;  
  if (index >= 8.0 && index < 11.0) return 3; 
  return 4;                          
}

void writeData(float uv, uint8_t battery) {
  File file = LittleFS.open("/uv_datalog.csv", FILE_APPEND);
  if(!file) return;

  struct tm timeinfo;
  time_t time = currentTime; 
  localtime_r(&time, &timeinfo);
  char timeString[25];
  
  if (currentTime == 0) {
     sprintf(timeString, "UNSYNCED");
  } else {
     strftime(timeString, sizeof(timeString), "%Y-%m-%d %H:%M:%S", &timeinfo);
  }

  file.print(timeString); file.print(",");
  file.print(uv, 2); file.print(",");
  file.println(battery);
  file.close();
}

void deepSleep(int time) {  
  esp_sleep_enable_ext1_wakeup(1ULL << BUTTON, ESP_EXT1_WAKEUP_ANY_HIGH);
  esp_sleep_enable_timer_wakeup(time * uS_TO_S_FACTOR);
  
  Serial.flush();
  tft.fillScreen(ST77XX_BLACK); 
  esp_deep_sleep_start();
}

// ==========================================
//          MAIN FREERTOS TASK
// ==========================================
void mainTaskCode(void * pvParameters) {
  for(;;) {

    if (currentTime > 0) currentTime++;
    
    if (deviceConnected && triggerAutoSync) {
      vTaskDelay(2000 / portTICK_PERIOD_MS); 
      syncHistoricalData();
      triggerAutoSync = false;
    }

    float general = readSensor(genSen);
    float sunscreen = readSensor(sunSen);
    uint8_t percent = getBattery();

    float matrixVal = limits[skinType - 1][getColumn(general)] * ( (float)spf / 30.0 );
    matrixVal = max(1.0, matrixVal);
    float ratio = 200.0 / (matrixVal * 60);

    if (general > 1){
      counter -= ratio;
    }
    
    if ( (sunscreen/general > 0.75 || sunscreen > 2) && general > 3) {
      counter = 0.0;
    }

    writeData(general, percent);
    
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

    if (deviceConnected && !isSyncing) {
        pTxBattery->setValue(&percent, 1);
        pTxBattery->notify();
        pTxUV->setValue((uint8_t*)&general, 4); 
        pTxUV->notify();
        pTxMinutes->setValue((uint8_t*)&counter, 4); 
        pTxMinutes->notify();
    }

    if (counter <= 0 && !motorMode) {
      digitalWrite(MOTOR, HIGH);
      motorMode = true;
      if (!screenMode) {
          tft.fillScreen(ST77XX_BLUE);
          screenMode = true;
      }
    }

    if (digitalRead(BUTTON) == HIGH) {
      counter = 200.0;
      digitalWrite(MOTOR, LOW);
      motorMode = false;
      awakeTime = 0;
    }
    
    awakeTime++;
    if (awakeTime >= 10 && !deviceConnected && !motorMode) {
      int sleepTime = TIME_TO_SLEEP; 
      if (secondsLeft > 0 && secondsLeft < TIME_TO_SLEEP) {
          sleepTime = (int)secondsLeft;
      }
      screenMode = false;
      counter -= ratio * sleepTime;
      if (currentTime > 0) {
        currentTime += sleepTime;
      }
      deepSleep(sleepTime);
    }

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

    vTaskDelay(1000 / portTICK_PERIOD_MS); 
  }
}

// ==========================================
//          SETUP & LOOP
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
  
  if (!LittleFS.begin(true)) {
    Serial.println("LittleFS Mount Failed. Formatting...");
  }

  bluetoothSetup();
  screenSetup(); 

  xTaskCreatePinnedToCore(mainTaskCode, "MainTask", 8192, NULL, 1, &MainTask, 0); 
}

void loop() {
  vTaskDelay(1000 / portTICK_PERIOD_MS);
}
