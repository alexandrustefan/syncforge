# Security

SyncForge captures system audio and can open the microphone during calibration and optional Live
Sync. It is not sandboxed. Audio analysis runs locally; microphone samples are not written to disk
or uploaded. Settings and diagnostic logs are stored locally.

## Report a vulnerability

Please use GitHub's private vulnerability reporting:

https://github.com/alexandrustefan/syncforge/security/advisories/new

Describe the affected commit, impact and minimal reproduction. Do not include credentials, private
recordings, signing keys, device UIDs or unnecessary personal information. Please avoid posting
exploit details in a public issue before the report has been assessed.

This is an early project. Fixes target the current `main` branch; there is no separate supported
release line or guaranteed response time. Ordinary audio glitches and feature requests can use
public issues after personal information has been removed.
