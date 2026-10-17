# Using SyncForge


1. **Pick outputs.** Click the menu bar icon (two speakers), tick your outputs and switch SyncForge **on**.
   While it's on, macOS audio plays only through the outputs you selected. Switch it off or quit, and macOS
   plays normally again.
2. **Calibrate.** Open *Calibration* and follow the three steps:
   1. **Microphone:** choose one and put it where you sit. The MacBook mic is fine; an **iPhone** (Continuity)
      can sit exactly at your head position.
   2. **Calibrate:** *Start Calibration*. Each speaker plays a few soft sweeps (about 30–40 s in total;
      music is muted meanwhile). Delays, tone correction and (optionally) level matching are applied
      automatically.
   3. **Live Sync** can turn on automatically after a successful calibration. It monitors candidate
      wireless latency changes while music plays; reflections and weak signals can remain ambiguous.

   *Start Over…* forgets every measurement, delay, correction and level trim.
3. **Fine-tune by ear (optional).** *Sync Test* plays one click on every output. Nudge *Fine trim*
   (±1 / ±0.1 ms) until you hear a single sharp click.
4. **Equalize.** *Equalizer → All Outputs (System EQ)* shapes the overall sound; pick a speaker to adjust it
   on its own. A speaker's graph shows its own curve, the combined curve (dashed orange) and what the mic
   measured (grey).

**Tips**
- **Quieter speakers** (e.g. MacBook speakers): use *Match speaker levels*, or raise that speaker's *Preamp*
  with *Prevent clipping* on.
- **Volume keys** control every output together (*Settings → macOS volume controls all outputs*).
- **Keyboard shortcuts** (main window): ⌘⇧E on/off · ⌘⇧K calibrate · ⌥⌘↑/↓ volume · ⌥⌘M mute · ⌘1–5 sections.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Outputs silent, source meter flat | Allow *System Audio Recording*: System Settings › Privacy & Security › Screen & System Audio Recording › SyncForge. |
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
