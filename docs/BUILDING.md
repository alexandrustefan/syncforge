# Building SyncForge

## Requirements

- macOS 14.4 or later.
- Full Xcode 16.4 or later, including its macOS SDK. CI uses Xcode 16.4 on macOS 15.
- XcodeGen (`brew install xcodegen`).

Select your full Xcode installation in Xcode's Settings → Locations → Command Line Tools, then
complete any first-launch setup Xcode requests. Check the selected toolchain with:

```sh
xcodebuild -version
swift --version
```

`SyncForgeKit` uses Swift Package Manager and Apple system frameworks only. No third-party runtime
packages are downloaded by the package. `project.yml` is the source of truth for the app project;
the generated Xcode project is checked in so you can also open it directly.

## Local build

From the repository root:

```sh
scripts/build.sh --test
```

This runs release tests, regenerates the Xcode project, and builds `build/SyncForge.app`. The log is
`build/xcodebuild.log`. It does not install, launch the app, open audio devices or run calibration.

```sh
scripts/build.sh --debug         # Debug instead of Release
scripts/build.sh --install       # quit the installed app and replace ~/Applications/SyncForge.app
open ~/Applications/SyncForge.app
```

`--install` interrupts an existing SyncForge session. For a manual install, quit SyncForge and move
`build/SyncForge.app` to `~/Applications` with Finder. The app's settings stay in Application Support.
The current source build is not Developer ID notarized; no prebuilt public binary is provided.

## Signing and permissions

Without another identity, the build script uses ad-hoc signing. Ad-hoc rebuilds can make macOS ask
for System Audio Recording and Microphone permissions again. For a stable local identity:

```sh
scripts/create-signing-identity.sh
scripts/build.sh --test --install
```

The identity script generates a self-signed code-signing certificate and private key, imports them
into your login keychain, and removes its temporary files. macOS may ask to authorize `codesign`
to use that key. This is a local development identity, not Apple Developer ID or notarization.
Never upload your private key, `.p12` export or keychain.

The build selects `SyncForge Local Signing` if that certificate exists. Override it explicitly:

```sh
SYNCFORGE_SIGN_IDENTITY=- scripts/build.sh       # force ad-hoc signing, as in CI
SYNCFORGE_SIGN_IDENTITY="Your Signing Identity" scripts/build.sh
```

Allow System Audio Recording in System Settings → Privacy & Security. Calibration and optional
Live Sync need Microphone access too. SyncForge itself does not upload recordings or save samples.

## Tests and offline benchmark

```sh
cd SyncForgeKit
swift test -c release
swift test --scratch-path ../build/tsan --sanitize=thread --filter ConcurrencyTests
SYNCFORGE_LIVE_SYNC_BENCHMARK=1 swift test -c release --filter LiveSyncAnalysisTests/testOfflineBenchmark
```

Ordinary tests and the benchmark use synthetic audio and injected backends. They open no real audio
devices and do not qualify acoustics, permissions, reconnect, sleep/wake or long-run playback.
The benchmark is opt-in and does not enforce machine-dependent timing thresholds.

## Command-line hardware tools

Quit the GUI app first. Two capture engines can capture each other's output.

```sh
cd SyncForgeKit
swift build -c release
.build/release/sfctl devices
.build/release/sfctl run --out 'OUTPUT_UID' --seconds 20
.build/release/sfctl calibrate --out 'WIRED_UID' --out 'BLUETOOTH_UID' --hold 15
.build/release/sfctl soak --out 'WIRED_UID' --out 'BLUETOOTH_UID' --seconds 1800
```

Use the UIDs from `sfctl devices`. `run` and `soak` route real system audio; `calibrate` plays test
sweeps. They require macOS privacy permissions for the process being run. `sfctl` reports renderer
servo lock separately from acoustic calibration: a small servo error does not prove synchronized
sound at your listening position. See [validation](VALIDATION.md) before interpreting results.

## Project map

```text
App/SyncForge/                       SwiftUI app, assets, permissions
SyncForgeKit/Sources/SyncForgeCore/  device coordination, DSP design, calibration, profiles
SyncForgeKit/Sources/SyncForgeRT/    C11 audio callbacks, ring, resampler, limiter
SyncForgeKit/Sources/sfctl/          command-line validation tools
SyncForgeKit/Tests/                 DSP, kernel simulation, lifecycle and concurrency tests
scripts/                           build, local signing and icon generation
docs/                              design, usage, measurements and research
project.yml                        XcodeGen app specification
```
