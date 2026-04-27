#include <Arduino.h>
#include "driver/rtc_io.h"
#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLEClient.h>
#include "BLEScan.h"
#include <BLE2902.h>

// pin out
#define BUTTON    GPIO_NUM_4
#define MOTOR     17
#define genSen    6          
#define sunSen    5           
#define battery   0           
#define TFT_CS    20 
#define TFT_RST   19
#define TFT_DC    7 

Adafruit_ST7789 tft = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_RST);

// variables
#define uS_TO_S_FACTOR 1000000ULL
#define TIME_TO_SLEEP  30 
RTC_DATA_ATTR float counter = 200.0; 
RTC_DATA_ATTR int spf = 30; 
RTC_DATA_ATTR int skinType = 1; 
bool deviceConnected = false;
bool motorMode = false; 
bool screenMode = false;
unsigned long previousMillis = 0;
const long interval = 1000; // 1 second interval
int awakeTime = 0; 
int limits[][5] = { 
  {120, 60, 40, 20, 10},
  {120, 80, 60, 30, 20},
  {180,100, 80, 40, 30},
  {180,120,100, 60, 40},
  {200,140,120, 80, 60},
  {200,160,140,100, 80}
};

// ble values
#define SERVICE_UUID                "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX_SPF  "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_RX_SKN  "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX_DAT  "6E400004-B5A3-F393-E0A9-E50E24DCCA9E"  
#define CHARACTERISTIC_UUID_TX_UV   "6E400005-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_TX_MIN  "6E400006-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_TX_BAT  "6E400007-B5A3-F393-E0A9-E50E24DCCA9E" 
#define CHARACTERISTIC_UUID_TX_SYNC "6E400008-B5A3-F393-E0A9-E50E24DCCA9E"
BLEServer *pServer = NULL;
BLECharacteristic *pTxUV;
BLECharacteristic *pTxMinutes;
BLECharacteristic *pTxBattery;

// ble functions
// change variable showing if bluetooth connection is active or not
// if not, open to connection
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) { 
      deviceConnected = true; 
    }
    void onDisconnect(BLEServer* pServer) { 
      deviceConnected = false; 
      pServer->getAdvertising()->start(); 
    }
};

// set spf value if new value is sent from app
class SpfCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) override {
      String data = pCharacteristic->getValue();
      if (data.length() > 0) spf = data.toInt(); 
    }
};

// set skin type value if new value is sent from app
class SkinCallback: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) override {
      String data = pCharacteristic->getValue();
      if (data.length() > 0) skinType = data.toInt(); 
    }
};

// initialize bluetooth 
void bluetoothSetup() {
  // main service
  BLEDevice::init("SunShield");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService *pMain = pServer->createService(SERVICE_UUID);
  
  // set up characteristics to send data to app
  pTxUV = pMain->createCharacteristic(CHARACTERISTIC_UUID_TX_UV, BLECharacteristic::PROPERTY_NOTIFY);
  pTxUV->addDescriptor(new BLE2902());
  pTxMinutes = pMain->createCharacteristic(CHARACTERISTIC_UUID_TX_MIN, BLECharacteristic::PROPERTY_NOTIFY);
  pTxMinutes->addDescriptor(new BLE2902());
  pTxBattery = pMain->createCharacteristic(CHARACTERISTIC_UUID_TX_BAT, BLECharacteristic::PROPERTY_NOTIFY);
  pTxBattery->addDescriptor(new BLE2902());

  // set up characteristics to receive data from app
  BLECharacteristic *pRxSpf = pMain->createCharacteristic(CHARACTERISTIC_UUID_RX_SPF, BLECharacteristic::PROPERTY_WRITE);
  pRxSpf->setCallbacks(new SpfCallback());
  BLECharacteristic *pRxSkin = pMain->createCharacteristic(CHARACTERISTIC_UUID_RX_SKN, BLECharacteristic::PROPERTY_WRITE);
  pRxSkin->setCallbacks(new SkinCallback());

  // open to connection
  pMain->start();
  pServer->getAdvertising()->start();
}

// initialize pins
void pinSetup() { 
  pinMode(genSen, INPUT);
  pinMode(sunSen, INPUT);
  pinMode(BUTTON, INPUT_PULLDOWN); 
  rtc_gpio_pullup_dis(BUTTON);
  rtc_gpio_pulldown_en(BUTTON);
  pinMode(MOTOR, OUTPUT);
  digitalWrite(MOTOR, LOW); 
}

// initialize screen
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

// read uv sensors and return calibrated uv index
float readSensor(int sensor) {
  float index = analogRead(sensor) * (3.3 / 4095.0) / 0.1;
  float calibrated = (index * 12.5) - 17.0;
  if (calibrated < 0.0) {
    calibrated = 0.0;
  }
  return calibrated;
}

// read voltage and return calibrated battery percentage
uint8_t getBattery() {
  float percentage = analogReadMilliVolts(battery);
  float calibrated = (3.7 - percentage) / 37;
  return percentage;
}

// match uv value to column in matrix for time limits
int getColumn(float index) {
  if (index < 3.0) return 0;       
  if (index >= 3.0 && index < 6.0) return 1;  
  if (index >= 6.0 && index < 8.0) return 2;  
  if (index >= 8.0 && index < 11.0) return 3; 
  return 4;                          
}

// put esp into sleep mode for given amount of time
void deepSleep(int time) {  
  // allow for wakeup on button press
  esp_sleep_enable_ext1_wakeup(1ULL << BUTTON, ESP_EXT1_WAKEUP_ANY_HIGH);
  // wake up every 30 seconds to read sensors
  esp_sleep_enable_timer_wakeup(time * uS_TO_S_FACTOR);
  
  Serial.flush();
  // turn off screen when in sleep mode
  tft.fillScreen(ST77XX_BLACK); 
  esp_deep_sleep_start();
}

void setup() {
  Serial.begin(115200);
  // leave screen off if only waking up to read sensors
  esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  if(cause == ESP_SLEEP_WAKEUP_TIMER) {
      screenMode = false;
    } else {
      screenMode = true; 
    }
  // run other setup functions
  pinSetup();
  bluetoothSetup();
  screenSetup(); 
}

void loop() {
  // get current time to check how long it has been since last reading
  unsigned long currentMillis = millis();

  // perform functions once per second (interval is one second)
  if (currentMillis - previousMillis >= interval) {
    previousMillis = currentMillis;

    // read data
    float general = readSensor(genSen);
    float sunscreen = readSensor(sunSen);
    uint8_t percent = getBattery();
    
    // use uv readings to check how quickly to count down
    float matrixVal = limits[skinType - 1][getColumn(general)] * ( (float)spf / 30.0 );
    matrixVal = max((float)1.0, matrixVal);
    float ratio = 200.0 / (matrixVal * 60);

    // only count down if uv index is over 1
    if (general > 1){
      counter -= ratio;
    }
    
    // alert to reapply if sunscreen and general sensor are reading similar values and actual value is over 3 (able to get sunburnt)
    if (general - sunscreen < 0.5 && general > 3) {
      counter = 0.0;
    }

    // if countdown reaches 0, turn on vibration motor and screen (if off)
    if (counter <= 0 && !motorMode) {
      digitalWrite(MOTOR, HIGH);
      motorMode = true;
      if (!screenMode) {
          tft.fillScreen(ST77XX_BLUE);
          screenMode = true;
      }
    }

    // reset when button is pressed
    if (digitalRead(BUTTON) == HIGH) {
      counter = 200.0;
      digitalWrite(MOTOR, LOW);
      motorMode = false;
      awakeTime = 0;
    }
    
    // calculate time left
    float secondsLeft = (counter / 200.0) * (matrixVal * 60.0);
    int minutes = secondsLeft / 60;
    int seconds = (int)secondsLeft % 60;

    // update screen
    if (screenMode) {
      // alert to reapply sunscreen if motor is on, otherwise show time left
      tft.setCursor(0, 50);
      if (motorMode) {
        tft.print("Reapply sunscreen!");
      }
      else{
        tft.printf("Time: %02d:%02d              ", minutes, seconds);
      }
      // display uv index
      tft.setCursor(0, 100);
      tft.print("UV: " + String(general, 1) + "  ");
      // display battery left
      tft.setCursor(0, 150);
      tft.print("Battery: " + String(percent) + "%  ");
    }

    // send battery, uv, and time data if there is an active ble connection
    if (deviceConnected) {
        pTxBattery->setValue(&percent, 1);
        pTxBattery->notify();
        pTxUV->setValue((uint8_t*)&general, 4); 
        pTxUV->notify();
        pTxMinutes->setValue((uint8_t*)&counter, 4); 
        pTxMinutes->notify();
    }
    
    // check how long esp has been awake for
    awakeTime++;
    // if awake for ten seconds, timer isn't going off, and no ble connection, go to sleep
    if (awakeTime >= 10 && !deviceConnected && !motorMode) {
      int sleepTime = TIME_TO_SLEEP; 
      // sleep for either 30 seconds or remaining amount of time left (if less than 30s)
      if (secondsLeft > 0 && secondsLeft < TIME_TO_SLEEP) {
          sleepTime = (int)secondsLeft;
      }
      // turn off screen and decrement counter for time asleep
      screenMode = false;
      counter -= ratio * sleepTime;
      deepSleep(sleepTime);
    }

    // debug through serial
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
}