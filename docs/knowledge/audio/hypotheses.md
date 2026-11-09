
## AirPods pauses read as a dead microphone (2026-11-09, unconfirmed — no log yet)
- Symptom on a friend's Mac with AirPods: "No sound is reaching Whisperer. Trying to restart the microphone…" left on the panel next to "Ready".
- Hypothesis: AirPods' noise suppression gates the mic below the -60 dBFS silence floor during pauses, so the 1.5 s dead-input rule (18 callbacks, tuned for the built-in mic's -50 dBFS room noise) fired on ordinary pauses and rebuilt the engine, renegotiating the Bluetooth link.
- Change: silence counted in seconds of audio; Bluetooth inputs get 6 s before any signal, 20 s after; a non-terminal warning clears when the recording ends.
- To confirm: an AirPods log showing `eng.retry reason=silence_1.5s` with `transport=bluetooth` during speech pauses, or the RMS AirPods deliver while the wearer is silent.
