# SunShield

## Project Overview
This repository contains the embedded firmware and iOS app software for **SunShield**, a wearable device that monitors UV radiation and tracks physical sunscreen effectiveness. The firmware runs on a ESP32-C6 microcontroller and calculates a countdown based on real-time sensor data, the user's skin type, and applied SPF. The app communicates with the wearable via BLE to display UV data and send user-specific parameters.

---

## Core Features
* Utilizes a non-blocking `millis()` timer architecture to continuously update a countdown timer keeping users safe from sunburns. 
* Implements autonomous deep sleep cycles (up to 30 seconds) during inactivity. Essential variables (timer, SPF, skin type) are retained in non-volatile RTC memory (`RTC_DATA_ATTR`).
* Uses the `EXT1` RTC-muxed wake-up controller to allow instantaneous device wake-up via a button press.
* Applies a linear regression model to UV readings to account for acrylic encasing.
* Continuously monitors the transmission ratio between an ambient UV sensor and a sunscreen-coated UV sensor to detect physical barrier degradation in case bypassing timer alert is necessary.
* Facilitates bidirectional communication between device and iOS app to transmit and receive data.
* Displays real-time UV index, countdown timer, and battery level in a mobile interface
* Enables user input for skin type and SPF, which dynamically updates device calculations
* Uses reactive UI updates to reflect live data without manual refresh
* Provides connection status and debugging interface for BLE communication

---

## Technologies Used
- **Embedded**: ESP32-C6, Arduino Framework  
- **Mobile App**: SwiftUI, CoreBluetooth  
- **Communication**: Bluetooth Low Energy (BLE)  
- **Sensors**: Analog UV sensors (Adafruit GUVA)

---

## Firmware

### Libraries
This project is built using the Arduino IDE framework. You will need the following libraries:
1. `Adafruit GFX Library`
2. `Adafruit ST7789 Library`

### Flashing Instructions
1. Open the Arduino IDE.
2. Go to **Boards Manager**, search for `esp32`, and install the latest version.
3. Install the required Adafruit libraries via **Library Manager**.
4. Connect the ESP32-C6 to your computer.
5. Open the `EE496_EmbeddedSoftware.ino` file.
6. Select **DFRobot ESP32-C6** as the **Board**.
7. Select the appropriate COM port.
8. Click **Upload**.

---

## iOS App

### System Overview
SunShield is composed of three main subsystems:

- **Hardware**: UV sensors, ESP32-C6 microcontroller, LCD display, and vibration motor  
- **Embedded Software**: Processes sensor data and computes exposure countdown  
- **Mobile Application (iOS)**: Displays real-time data and allows user configuration  

Data flows from the wearable to the mobile app via BLE, while user settings are transmitted back to the device.

### Mobile App Setup
* Open project in Xcode and run on a physical iOS device
* Ensure Bluetooth permissions are enabled in Info.plist
* Power on ESP32 and tap “Scan” in the app to connect
* Verify device name matches advertised name (e.g., "SunShield")

---

## BLE Communication Protocol
* For bluetooth integration, the ESP32-C6 acts as a BLE server.
* iOS app acts as BLE central device and connects to ESP32 peripheral
* Subscribes to notify characteristics for continuous real-time data updates
* Writes user settings (SPF, skin type) to ESP32 via RX characteristics
* Parses incoming binary data (float, uint8) for efficient communication

**Main Service UUID:** `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`

### Write Characteristics (RX - App to ESP32)
* **SPF**
* **Skin Type**

### Notify Characteristics (TX - ESP32 to App)
* **UV Index** 
* **Remaining Minutes** 
* **Battery Percentage**
