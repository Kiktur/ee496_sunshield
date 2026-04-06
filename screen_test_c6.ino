// #include "DFRobot_GDL.h"
// // #include <SPI.h> // Not sure if this needs to be included
// #include <Adafruit_ST7789.h> // Reference ST7789 library

#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>

// Define pins for the LCD (MISO, MOSI, and SCLK are defaulted to specific pins; see pinout diagram)
#define TFT_CS 5 // Chip select
#define TFT_RST 6 // Reset
#define TFT_DC 7 // Data/command select
#define backlight_pin 17 // Example: GPIO 2

// Needs Adafruit ST7735 and ST7789 library
Adafruit_ST7789 tft = Adafruit_ST7789(TFT_CS, TFT_DC, TFT_RST);




void setup() {

Serial.begin(115200);
pinMode(backlight_pin, OUTPUT);

// Initialize display
tft.init(240, 240); // Use your screen resolution
tft.setRotation(2); // Adjust rotation if needed
tft.fillScreen(ST77XX_BLACK); // Initial color fill
tft.setTextColor(ST77XX_WHITE); // Choose your text color
tft.setTextSize(2); // Adjust as needed
tft.setCursor(10, 10); // X, Y position
tft.invertDisplay(true); // Actually preserves defined colors? (value of true DOESNT invert colors)

}

int counter = 0;


void loop() {
  	// tft.drawRGBBitmap(pDraw->iX, pDraw->iY + pDraw->y, lineBuffer, pDraw->iWidth, 1);
    // if (pDraw->y == (pDraw->iHeight - 1)) {
    // tft.setTextColor(ST77XX_WHITE, ST77XX_WHITE); // Optional: erase previous text background
    // tft.setTextSize(2);
    digitalWrite(backlight_pin, HIGH);
    
    tft.fillScreen(ST77XX_BLUE); // Initial color fill
    tft.setCursor(100, 100);
    tft.print(String(counter));
    Serial.println(counter);
    delay(1000);
    counter++;
}
