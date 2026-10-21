/*
 * LightTalk Transmitter — Arduino sketch
 *
 * Blinks an LED to transmit text as light, using the LightTalk v1 protocol.
 * A phone running the LightTalk app decodes it in real time through the camera.
 *
 * Wiring:
 *   Option A (easiest): use the built-in LED on pin 13. Set LED_PIN = 13.
 *   Option B (brighter, better for daylight demos): external high-brightness LED
 *     from digital pin 8 through a 220-ohm resistor to GND. Set LED_PIN = 8.
 *     Long leg (anode) -> resistor -> pin 8. Short leg (cathode) -> GND.
 *
 * Protocol (must match BlinkProtocol.swift — do not change one without the other):
 *   - 6-bit alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :-./?" (MSB first)
 *   - 7 bits per character: 6 data bits + 1 even-parity bit
 *   - Frame: PREAMBLE 10101010, START 111000, characters..., END 111111,
 *     then LED off for 2 s, then the loop repeats.
 *   (END is all-ones so no letter — e.g. H = 000111 — can be mistaken for it.)
 *   - Bit duration: 200 ms (5 bits/sec)
 */

const int LED_PIN = 13;                 // 13 = built-in LED, or 8 = external LED
const unsigned long BIT_MS = 200;
const unsigned long GAP_MS = 2000;

// Change this to any message using the alphabet above (auto-uppercased).
// Keep it short: every character costs ~0.7 s of airtime.
const char* MESSAGE = "WTR 1400";

// Camp-coordination presets — uncomment the one you want the beacon to loop.
// const char* MESSAGE = "WTR 1400";    // water truck 2 PM  (~24 s)
// const char* MESSAGE = "MED 3";       // medical tent moved (~20 s)
// const char* MESSAGE = "FOOD 1800";   // food 6 PM          (~27 s)
// const char* MESSAGE = "CRFW 2000";   // curfew 8 PM        (~30 s)
// const char* MESSAGE = "SHL B";       // shelter B open     (~20 s)
// const char* MESSAGE = "ALCLR";       // all clear          (~20 s)
// Device diagnostics:
// const char* MESSAGE = "T23 OK";
// const char* MESSAGE = "FNFLT";
// const char* MESSAGE = "BATLO";

const char ALPHABET[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :-./?";

void setup() {
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);
  Serial.begin(9600);
  Serial.print("LightTalk beacon ready. Message: ");
  Serial.println(MESSAGE);
}

void sendBit(int b) {
  digitalWrite(LED_PIN, b ? HIGH : LOW);
  delay(BIT_MS);
}

int charCode(char c) {
  if (c >= 'a' && c <= 'z') c = c - 'a' + 'A';  // uppercase it
  for (int i = 0; ALPHABET[i] != '\0'; i++) {
    if (ALPHABET[i] == c) return i;
  }
  return -1;  // not in alphabet -> skipped
}

void sendChar(char c) {
  int code = charCode(c);
  if (code < 0) return;
  int ones = 0;
  for (int shift = 5; shift >= 0; shift--) {   // 6 data bits, MSB first
    int b = (code >> shift) & 1;
    ones += b;
    sendBit(b);
  }
  sendBit(ones % 2 == 0 ? 0 : 1);             // even parity bit
}

void loop() {
  // Preamble: alternating bits — the phone calibrates bright/dim levels here.
  int preamble[8] = {1,0,1,0,1,0,1,0};
  for (int i = 0; i < 8; i++) sendBit(preamble[i]);

  // Start marker.
  int start[6] = {1,1,1,0,0,0};
  for (int i = 0; i < 6; i++) sendBit(start[i]);

  // Message.
  for (int i = 0; MESSAGE[i] != '\0'; i++) sendChar(MESSAGE[i]);

  // End marker, then a dark gap before the loop repeats.
  int endm[6] = {1,1,1,1,1,1};
  for (int i = 0; i < 6; i++) sendBit(endm[i]);

  digitalWrite(LED_PIN, LOW);
  delay(GAP_MS);
}
