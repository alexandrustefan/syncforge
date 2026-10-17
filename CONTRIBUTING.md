# Contributing

SyncForge is an early public project. Reproducible bugs, hardware test reports and focused fixes
are welcome. Open an issue before a large feature or architectural change so its scope can be discussed.

## Work on a change

1. Fork the repository and create a branch.
2. Follow [building from source](docs/BUILDING.md). Use `project.yml` for project configuration, then
   regenerate with `xcodegen generate` when it changes.
3. Keep changes focused. Preserve existing profiles and backwards-compatible saved-state decoding.
4. Run the relevant tests and the release build. Explain the problem, behavior change and validation
   in your pull request.

```sh
cd SyncForgeKit
swift test -c release
cd ..
SYNCFORGE_SIGN_IDENTITY=- scripts/build.sh
```

For changes to C concurrency or handoffs, also run:

```sh
cd SyncForgeKit
swift test --scratch-path ../build/tsan --sanitize=thread --filter ConcurrencyTests
```

Swift uses four-space indentation. The real-time callbacks stay in C: no allocation, blocking locks,
Swift/Objective-C runtime calls or unbounded retry loops. Cross-thread payloads must follow the C11
memory model; a sequence counter does not make concurrent plain struct copies safe.

## Report what you tested

Separate build/test evidence from hardware behavior and independently measured acoustic timing.
For audio reports include macOS and Xcode versions, CPU architecture, speaker/microphone models,
connection types, sample rates, reproduction steps and whether the app or `sfctl` was used.
Do not run both capture engines together.

Review excerpts before sharing them. Device UIDs may contain hardware identifiers, and settings/logs
may reveal names or local paths. Do not attach microphone recordings, whole keychains, signing
identities or unredacted state files. Security issues belong in [private reporting](SECURITY.md).

## License

By submitting a contribution, you agree that it can be distributed under this repository's
[MIT license](LICENSE). AI-assisted contributions are welcome; authors remain responsible for
understanding the change and providing evidence for its behavior.
