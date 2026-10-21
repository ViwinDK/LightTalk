# LightTalk Setup Guide — Arduino + iPhone, step by step

Two independent tracks. Do the Arduino track first (15 minutes, no Xcode needed).

---

## TRACK 1 — Arduino transmitter

### What you need
- Any Arduino board (Uno, Nano, Mega — whatever you have)
- USB cable that carries **data** (some cheap cables are charge-only — if the
  board never appears in the port menu, suspect the cable first)
- Mac with internet access

### Steps
1. Download the **Arduino IDE** from `arduino.cc/en/software` (version 2.x).
   Install it like any Mac app.
2. Plug the Arduino into the Mac with the USB cable. A power LED on the board
   should light up.
3. Open the Arduino IDE. Go to **Tools → Board** and pick your board
   (e.g. *Arduino AVR Boards → Arduino Uno*).
4. Go to **Tools → Port** and pick the port with your board's name in it
   (looks like `/dev/cu.usbmodem…`).
   - **No port listed?** If it's a low-cost clone board it probably uses a
     CH340 USB chip — install the driver from the chip maker's site
     (`wch.cn`), restart the IDE, and check the Port menu again.
5. **File → Open** → navigate to `Transmitter.ino` from the LightTalk folder.
6. Near the top of the file, set your message:
   ```cpp
   const char* MESSAGE = "WATER 14:00";
   ```
   Only these characters are allowed: `A-Z 0-9` and `space : - . / ?`
   (lowercase is auto-uppercased).
7. Choose your LED:
   - **Easiest (no wiring):** leave `LED_PIN = 13` — this uses the Arduino's
     built-in LED (marked "L" on the board).
   - **Brighter (better for daylight demos):** wire an external high-brightness
     LED to pin 8: LED long leg → 220 Ω resistor → pin 8; LED short leg → GND.
     Then set `LED_PIN = 8`.
8. Click **Upload** (the → arrow button). Wait for "Done uploading."
9. Verify: the LED starts looping. You'll see ~3 seconds of fast blinking
   (the preamble), then the message, then a 2-second dark pause, then repeat.
   Open **Tools → Serial Monitor** (set to 9600 baud) to see the message echoed
   as confirmation.

### Arduino troubleshooting
| Symptom | Fix |
|---|---|
| No port in Tools → Port | Try another USB cable (must be data-capable); try another USB port; install CH340 driver for clone boards |
| Upload fails | Re-check Board + Port; close Serial Monitor and Serial Plotter, then retry |
| "Done uploading" but LED dark | Check `LED_PIN` matches your wiring; for external LED, check resistor is in series and legs aren't swapped |
| LED blinks but looks random | That's the message — it's supposed to look like that. Time one loop: `WATER 14:00` takes ~38 s |

---

## TRACK 2 — iPhone app

### What you need
- Mac (the same one is fine)
- iPhone — **a real iPhone, not the Simulator** (the Simulator has no camera).
  Any iPhone with iOS 16+ works.
- Apple ID (free — no paid developer account needed)
- USB cable (or same Wi-Fi network for wireless debugging)

### Step 1 — Install Xcode 16.x (one-time, ~30 min)
1. Go to `developer.apple.com/download/more/` and sign in with the Apple ID.
2. Download the newest **Xcode 16.x** (NOT the App Store version — that one
   requires macOS 26.6, which this Mac doesn't have).
3. Double-click the `.xip` to expand it (needs ~30 GB free), drag Xcode into
   Applications, and launch it once. Agree to the license; let it finish
   installing components.

### Step 2 — Create the project
1. **File → New → Project → iOS → App → Next.**
2. Product Name: `LightTalk`. Interface: **SwiftUI**. Language: **Swift**.
   (Testing System / Storage: None.) Save it anywhere.
3. In the file list, select the generated `ContentView.swift` → Delete →
   **Move to Trash**. (The app's real entry point is `LightTalkApp.swift`.)
4. **File → Add Files to "LightTalk"…** → select these 7 files from the
   LightTalk folder:
   - `LightTalkApp.swift`, `BlinkDecoder.swift`, `BlinkDecoderView.swift`,
     `BlinkProtocol.swift`, `MessageIntelligence.swift`,
     `BeaconPresets.swift`, `BeaconTransmitView.swift`
   - Check **"Copy items if needed"** and make sure the **LightTalk target**
     is checked → Add.

### Step 3 — Permission strings (camera, location, mic, speech)
1. Click the blue project icon at the top of the file list → select the
   **LightTalk target** → **Info** tab.
2. Add these four rows (hover over any row → **+** → pick each key):
   - **Privacy - Camera Usage Description** → `LightTalk uses the camera to read messages from blinking LED beacons.`
   - **Privacy - Location When In Use Usage Description** → `LightTalk can flash your GPS coordinates as light for SOS signaling.`
   - **Privacy - Microphone Usage Description** → `LightTalk uses the microphone to dictate beacon messages by voice.`
   - **Privacy - Speech Recognition Usage Description** → `LightTalk transcribes your dictated beacon messages on-device.`
   (If a key is missing from the list, add it as a User-Defined Setting under
   Build Settings instead: `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription`, etc.)

### Step 4 — Signing (free Apple ID)
1. Same target → **Signing & Capabilities** tab.
2. **Team → Add an Account…** → sign in with the Apple ID → pick the
   Personal Team.
3. If Xcode complains the bundle identifier is taken, change it to something
   unique (e.g. `com.vinaya.lighttalk`).

### Step 5 — Put it on the iPhone
1. Plug the iPhone into the Mac with USB → unlock the phone → **Trust** the
   computer if asked.
2. On the iPhone: **Settings → Privacy & Security → Developer Mode → ON** →
   restart the phone when prompted. (Required on iOS 16+.)
3. In Xcode's top toolbar, change the run destination from a Simulator to
   **your iPhone**.
4. Press **Run (▶)**. The first build takes a few minutes.
5. If the phone says the app is from an untrusted developer:
   **Settings → General → VPN & Device Management → tap the Apple ID → Trust.**

### Step 6 — Decode your first message
**With Arduino:**
1. Open LightTalk → **Decode** tab → allow camera access.
2. Point the phone at the blinking LED, **tap the LED on screen** (yellow
   reticle marks the spot it's watching).
3. Tap **Start decoding**. You'll see "Calibrating to this light…" (the
   preamble — this is the daylight trick), then letters arriving live.
4. `WATER 14:00` takes ~35 seconds to arrive. Watch the signal meter:
   it should swing high/low with the blinks.

**With two phones (no Arduino):**
1. Phone A → **Beacon** tab → pick a message → **Start beacon**
   (its flashlight starts blinking).
2. Phone B → **Decode** tab → tap the flashlight on screen →
   **Start decoding**.
3. Hold them 1–3 feet apart, indoors. Don't stare into the flashlight.

### iPhone troubleshooting
| Symptom | Fix |
|---|---|
| Build errors | Copy the exact error text and send it over — most are fixed in one line |
| "No beacon found" | Move closer (1–3 ft); tap precisely on the LED; use a brighter LED; dim harsh overhead light hitting the LED directly |
| "Decoding… 0 characters" for a while | The app auto-retries the signal hunt after ~20 s. You can also Stop and Start again during the beacon's dark gap for the cleanest lock |
| Letters wrong / � characters | That's the parity check doing its job — re-tap the LED dead-center and retry; avoid shaking |
| Beacon tab: "no torch" | That device has no flashlight — use the Arduino path instead |
| App won't open a week later | Free provisioning expires after 7 days — plug in and press Run again |
| Badge says "Direct decode" | Normal under Xcode 16 — the AI assist needs the iOS 26 SDK; decoding works fully without it |

---

## Order of operations (recommended evening plan)
1. Arduino blinking (Track 1) — 15 min
2. Xcode install (Track 2, Step 1) — 30 min, mostly waiting
3. Project + files + signing (Steps 2–4) — 20 min
4. Run on iPhone + first decode (Steps 5–6) — 20 min

If anything breaks, the exact error message (Arduino IDE output or Xcode's
issue navigator) is the fastest path to a fix.
