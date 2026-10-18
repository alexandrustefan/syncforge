# Using SyncForge


1. **Pick outputs.** Click the menu bar icon (two speakers), tick your outputs and switch SyncForge **on**.
   While it's on, macOS audio plays only through the outputs you selected. Switch it off or quit, and macOS
   plays normally again.
2. **Calibrate.** Open *Calibration* or click *Calibrate…* in Outputs. Choose your Mac's built-in
   microphone or a compatible iPhone microphone through Continuity Camera, and place it where you sit.
   Select the speakers you want to align, keep the room quiet, and click *Start Calibration*.
   Each speaker plays short test sweeps; music is muted during measurement.

   *Calibration options* contains tone correction, optional level matching, test level and search
   range. Progress shows the speaker being measured and an approximate remaining time once enough
   sweeps have completed. Retries and verification can change that estimate.

   **Live Sync** is optional. With a calibrated wired and wireless pair, it can monitor changes in
   wireless delay while music plays. It keeps the microphone open; audio is processed locally in
   memory. Reflections and weak signals can remain ambiguous.

   *Calibration history* contains *Restore Previous Calibration*, which returns to the timing,
   correction and level trims from before the latest calibration change in this app session. It also
   remains available if verification failed after applying measurements. Resetting calibration clears
   measurements and derived adjustments; it can be undone.
3. **Fine-tune by ear (optional).** *Sync Test* plays one click on every output. Nudge *Fine trim*
   (±1 / ±0.1 ms) until you hear a single sharp click.
4. **Equalize.** *Equalizer → All Outputs (System EQ)* shapes the overall sound; pick a speaker to adjust it
   on its own. A speaker's graph shows its own curve, the combined curve (dashed orange) and what the mic
   measured (grey).

**Tips**
- **Setups:** save a configuration in Settings, then switch from the menu bar. New setups include
  system EQ, room correction, master volume/mute and buffering settings as well as speaker profiles.
  *Modified* means the current sound differs from the selected setup; *Update Current Setup* saves
  those changes. Older setups keep their original scope until updated. Engine power, microphone
  selection, Live Sync and login preferences are not changed by setup recall.
- **Solo:** listen to one enabled speaker during normal playback from Outputs or the menu bar.
  Click Solo again to restore the mix. Saved mute and volume settings remain intact; Live Sync waits
  while Solo is active.
- **Exact volume:** click a percentage, type a value from 0 to 100, and press Return. Escape cancels.
- **Compact outputs:** expand *Channels, timing & diagnostics* to adjust channels, delays and inspect
  diagnostics. Enabled outputs appear above unused devices.
- **Undo:** ⌘Z reverses audio edits, resets and setup changes; ⌘⇧Z reapplies them. A slider drag is one
  undo step. Undo history lasts for the current app session; text fields retain ordinary text undo.
- **Quieter speakers** (e.g. MacBook speakers): use *Match speaker levels*, or raise that speaker's *Preamp*
  with *Prevent clipping* on.
- **Volume keys** control every output together (*Settings → macOS volume controls all outputs*).
- **Keyboard shortcuts** (main window): ⌘⇧E on/off · ⌘⇧K calibrate · ⌥⌘↑/↓ volume · ⌥⌘M mute · ⌘1–5 sections.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Outputs silent, source meter flat | Allow *System Audio Recording*: System Settings › Privacy & Security › Screen & System Audio Recording › SyncForge. |
| Audio capture or an output failed | Use *Retry Audio* in the menu bar. Permission warnings offer *Open Permission Settings* instead. |
| Live Sync message is shortened | Expand its status in the menu bar to read the full reason. |
| Live Sync says "Calibrated with … — recalibrate" | Calibrate with the microphone that's selected now (one mic drives both). |
| Live Sync "Waiting for music" | It needs music playing; it pauses during test signals. |
| Speakers drift apart over time | Turn on Live Sync, or *Calibrate All* again. |
| One speaker much quieter | *Match speaker levels*, or raise its Preamp with *Prevent clipping* on. |
| "No test signal detected" | The speaker is off or muted, or the mic is too far away; raise *Test level*. |
| Bluetooth sounds like a phone call | A Bluetooth microphone was used; SyncForge refuses those by default. Use the built-in, USB or iPhone mic. |
| Crackles | Settings › Base latency (it also auto-raises after underruns). |
| Permissions asked again after a rebuild | Run `scripts/create-signing-identity.sh` once. |
| Something odd happened | `~/Library/Logs/SyncForge/activity.log` records calibrations, Live Sync decisions, glitches and restarts. |


See [building and CLI commands](BUILDING.md) for developer tools.
