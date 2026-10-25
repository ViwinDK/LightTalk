LightTalk
A phone that reads blinking lights. Point an iPhone at a flashing LED — an Arduino or a laptop screen — and LightTalk decodes the blinks into text in real time. No pairing, no radio, no network. Just light.
When the towers go down, the camp still has lights. LightTalk turns the lights into the message.
Built for the Congressional App Challenge 2026.
!Platform !Language !License
What it does
Decode — The camera watches a blinking light and turns flashes into text, live. Auto-aim finds the strongest blink in frame; tap to target a specific LED.
Understand — Decoded codes expand into plain meaning and translate on-device into Spanish, French, Hindi, Tamil, and Arabic. Built-in codebooks cover camp coordination (WTR 1400 → "Water truck arrives at 2:00 PM. Bring containers.") and screen-less device diagnostics (BATLO → "Battery low"). Free text translates through the on-device model.
Transmit — The phone becomes the beacon: its flashlight blinks any preset, custom message, or an SOS with GPS coordinates.
Your own codes — Define a camp's private shorthand (with wildcards: WTR * → "Water truck at *") and the phone learns it. Tap any code to edit its meaning; swipe a custom code to delete it.
History — Every decoded message is saved to a history log, so nothing received is lost.
Learn — A pipeline visualizer shows light pulses becoming bits becoming words. Tap any decoded character in the Bit Inspector to see its 7 transmitted bits and its parity check.
How it works
The protocol
Deliberately simple, so anything with a light can speak it:
Layer
Spec
Alphabet
6-bit, ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:-./? (64 symbols)
Error check
1 even-parity bit per character (7 bits/char total)
Frame
Preamble 10101010 → Start 111000 → characters → End 111111 → 2 s dark gap, looping
Bit duration
200 ms (5 bps)
The end marker is all-ones (code 63) specifically so no character can be mistaken for it — an earlier design used a marker identical to the letter H, and "HELLO" decoded as "HE".
The decode core is physics, not AI
Reading the light is fully deterministic: frame-by-frame brightness measurement, differential sampling (beacon region minus background), edge timing against the known bit cadence, and per-character parity verification. Characters that fail parity are flagged ⚠️, never silently guessed.
On-device AI (Apple's Foundation Models, iPhone 15 Pro+ on iOS 26) only touches the meaning afterward: expanding codes, translating, repairing flagged characters, and converting plain-English descriptions into beacon codes. Every AI suggestion is validated against the input before it is shown. The UI badge always tells the truth: "AI assist · on-device" or "Direct decode". With no AI available, the app still decodes everything and expands every built-in code — it degrades, it doesn't break.
Transmitters
Anything that can blink can transmit:
LightTalk/transmitter.html — Open in any browser; the screen becomes the beacon. Zero setup.
LightTalk/Transmitter.ino — Arduino sketch for a real LED (pin 13 built-in, or an external LED on pin 8).
The app itself — Beacon tab drives the iPhone flashlight.
Build
Open LightTalk.xcodeproj in Xcode 26.2 or later (the project targets iOS 26.2 — older Xcode versions cannot build it).
Select your development team under Signing & Capabilities.
Add the usage-description keys listed in LightTalk/SETUP-GUIDE.md (camera is required; the rest enable optional features).
Run on a physical iPhone — the Simulator has no camera.
Free Apple ID provisioning works; the install expires after 7 days and is refreshed by re-running from Xcode.
Requirements: iOS 26.2+. Apple Intelligence features (AI repair/translation of non-codebook text, description-to-code) require an iPhone 15 Pro or later running iOS 26; all other features work on any supported iPhone.
Honest limitations
The physics is not new — optical communication goes back to Bell's photophone (1880) and is standardized in IEEE 802.15.7. The contribution here is the system: a phone receiver, a ten-cent-LED transmitter, and on-device translation, aimed at places with light but no signal.
A phone camera is a poor light receiver (30 fps). The practical ceiling is ~10–15 bps, and direct sunlight needs a shaded or hooded beacon. This is a short-range, line-of-sight link — by design, and it is not a secure channel.
The planned v2 receiver (photodiode + ESP32) removes the camera bottleneck for ~10,000× the speed.
License
MIT — see LICENSE. Built by Viwin Dinesh Kumar, Pflugerville, Texas.
