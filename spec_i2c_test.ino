// Requires Sparkfun VEML6075 Arduino Library
#include <SparkFun_VEML6075_Arduino_Library.h>
VEML6075 uv; // Create a VEML6075 object 

void setup() {
  Serial.begin(115200);

  Wire.begin();

  // the VEML6075's begin function can take no parameters
  // It will return true on success or false on failure to communicate
  if (uv.begin() == false) {
    Serial.println("Unable to communicate with VEML6075.");
    while (1) ;
  }
  Serial.println("UVA, UVB, UV Index");
}


void loop() {
// Use the uva, uvb, and index functions to read calibrated UVA and UVB values and a 
// calculated UV index value between 0-11.
Serial.println("UVA, UVB, UV Index");
Serial.println(String(uv.uva()) + ", " + String(uv.uvb()) + ", " + String(uv.index()));
delay(1000);
}
