#include <Arduino.h>

#define uS_TO_S_FACTOR 1000000ULL  // Conversion factor for micro seconds to seconds
#define TIME_TO_SLEEP  5        // Time ESP32-C3 will sleep (in seconds)

RTC_DATA_ATTR int bootCount = 0; // Survives deep sleep (light sleep doesn't require this)

void setup(){
  Serial.begin(115200);
  delay(1000); // Take some time to open up the Serial Monitor
  if (bootCount == 0) {
    Serial.println("Initial boot");
    Serial.print("Boot count: ");
    Serial.println(bootCount);
  } else {
    Serial.println("Woke up");
    Serial.print("Boot count: ");
    Serial.println(bootCount);
  }
  bootCount++;
  delay(2000);

  // This line might be needed to separately turn off wifi/bluetooth
  //esp_wifi_stop()

  // Wake up after 5 seconds
  esp_sleep_enable_timer_wakeup(TIME_TO_SLEEP * uS_TO_S_FACTOR);
  Serial.println("Setup ESP32-C3 to sleep for " + String(TIME_TO_SLEEP) + " seconds");

  Serial.println("Going to sleep now");
  Serial.flush(); // Ensure all serial data is sent before sleeping


  esp_deep_sleep_start();
  
}

void loop(){
  // This is never reached
}
