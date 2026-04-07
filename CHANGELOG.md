# Changelog

## [0.3.0](https://github.com/IlyaGulya/wrenflow/compare/v0.2.0...v0.3.0) (2026-04-07)

Complete rewrite with Flutter UI and Rust backend. All transcription is now fully local — no cloud services, no API keys required.

### New Features

* fully local transcription using Parakeet TDT model — no internet needed ([5cd01fc](https://github.com/IlyaGulya/wrenflow/commit/5cd01fc019e793454e248e170a53d8f4751ab152))
* setup wizard for first-time configuration (permissions, model download) ([c8e2244](https://github.com/IlyaGulya/wrenflow/commit/c8e2244d91c3ddcaa30792f5325c4ad018f0939f))
* recording overlay with real-time waveform visualization ([9e1a574](https://github.com/IlyaGulya/wrenflow/commit/9e1a5742744accef42aa5440a2b53c851952380a))
* transcription history with expandable entries and timing metrics ([c5cb82d](https://github.com/IlyaGulya/wrenflow/commit/c5cb82d8844e4abc2a182eafa44d33a4b872559b))
* system tray with microphone selection and version info ([b51b367](https://github.com/IlyaGulya/wrenflow/commit/b51b367bf80bc4e3905d3caf7caaf13c6c838d9e))
* customizable global hotkey for push-to-talk recording ([93d7937](https://github.com/IlyaGulya/wrenflow/commit/93d7937a706b708cce68b7ae711fbcb86745474e))
* auto-update notifications from GitHub releases ([db399cf](https://github.com/IlyaGulya/wrenflow/commit/db399cfa670d09cb4cce8511d8f3105768221a28))
* error toast notifications ([3d64cb4](https://github.com/IlyaGulya/wrenflow/commit/3d64cb43c0431bad18200c58a348516ecbe82350))
* save recordings as OGG/Opus format (~15KB vs ~300KB WAV) ([048ad12](https://github.com/IlyaGulya/wrenflow/commit/048ad12f5cf4c3cabf0c59dbfe4cc42185d7fb38))
* launch at login support ([c8e2244](https://github.com/IlyaGulya/wrenflow/commit/c8e2244d91c3ddcaa30792f5325c4ad018f0939f))


### Bug Fixes

* prevent dock icon flash on startup ([03a0272](https://github.com/IlyaGulya/wrenflow/commit/03a0272dce75b9edd11df6502e2dd197353a928d))
* fix app icon not showing in Dock ([6b9cda8](https://github.com/IlyaGulya/wrenflow/commit/6b9cda89b4741cc2330c0998790ec4d520c5344e))
* reliable history persistence with SQLite ([0263d87](https://github.com/IlyaGulya/wrenflow/commit/0263d87207dfd4c217897300e6909c0b944a2ce0))


### Performance

* prewarm model on startup to eliminate first-transcription delay ([d895874](https://github.com/IlyaGulya/wrenflow/commit/d895874a69027cb9b258b9f7e5c62b07dd9c115a))
* transcribe from memory buffer, save recordings in parallel ([7a8f30a](https://github.com/IlyaGulya/wrenflow/commit/7a8f30a97cbe886d04d5bacd9c0d0208ce49343d))

## [0.2.0](https://github.com/IlyaGulya/wrenflow/compare/v0.1.0...v0.2.0) (2026-03-18)


### New Features

* **audio:** add cross-platform AudioCapture using cpal ([fbd2e31](https://github.com/IlyaGulya/wrenflow/commit/fbd2e314bb8fa2a5c0b6b02605de485ebffb2600))
* **ffi:** expose Groq models fetching via FFI, replace Swift HTTP calls ([3c56e23](https://github.com/IlyaGulya/wrenflow/commit/3c56e23c1adf1986eaf1604e8066f0e47b8273b6))
* **ffi:** expose HistoryStore via FFI, replace CoreData with Rust SQLite ([7265b1f](https://github.com/IlyaGulya/wrenflow/commit/7265b1fb98ccd2514ceb487baf56ec112cbcc353))
* **ffi:** expose post-processing via FFI, replace Swift HTTP calls ([6096e7a](https://github.com/IlyaGulya/wrenflow/commit/6096e7a0f8390cabfac3081877810f264e53dfe7))
* go local-first, remove cloud transcription, restructure settings ([5e99ff2](https://github.com/IlyaGulya/wrenflow/commit/5e99ff2634fa9640c0972a908557d052fb46ce69))
* **ui:** borderless settings with transparent titlebar ([156908a](https://github.com/IlyaGulya/wrenflow/commit/156908a191393ade4f648e369051f057c7e1f24b))
* **ui:** show PermissionGateView when permissions missing on hotkey ([de09f6d](https://github.com/IlyaGulya/wrenflow/commit/de09f6d47c47c118acef731d142cca4916b373fc))


### Bug Fixes

* **build:** fix release build, arm64 only, conditional linker settings ([50deb9e](https://github.com/IlyaGulya/wrenflow/commit/50deb9e289d6b3921fdafed776d050433b15b0f6))
* **ci:** fix action-semantic-pull-request SHA pin ([ab2d7ce](https://github.com/IlyaGulya/wrenflow/commit/ab2d7ce1a814c2d05d40f01268d6e8ef37050261))
* **ci:** fix ghalint download URL ([11044fd](https://github.com/IlyaGulya/wrenflow/commit/11044fd9ac99502d1d094403c0f529770d3724dc))
* **ci:** fix ghalint version, use actionlint download script ([a752ae8](https://github.com/IlyaGulya/wrenflow/commit/a752ae877b0e2536f85fd29b27f4f1d81cdc620f))
* **ci:** use action-semantic-pull-request v6.1.1 ([15c0151](https://github.com/IlyaGulya/wrenflow/commit/15c0151f5fc9b265c4bbb0174a64ff37488a298a))
* **ffi:** fix duplicate thiserror dep, regenerate UniFFI bindings ([fe9f876](https://github.com/IlyaGulya/wrenflow/commit/fe9f876afaec63d53d5a5842e2b08031e5f07a8a))
* **ffi:** fix history persistence, remove CoreData, hide disabled steps ([6ed225a](https://github.com/IlyaGulya/wrenflow/commit/6ed225ad8f4bc6cf62ce5d6a9d7dfbe8a7fa25d0))
* typed errors, audio format fix, settings polish ([4643324](https://github.com/IlyaGulya/wrenflow/commit/46433243e54b94f92224d986bede1fcb4fcc1ea5))
* **ui:** error toast, audio crash fix, settings polish ([f88030d](https://github.com/IlyaGulya/wrenflow/commit/f88030d83bf39c5272d62f1da4666c5d431f3f3e))
* **ui:** fix permissions flow, remove Requesting state, fix polling ([32956e0](https://github.com/IlyaGulya/wrenflow/commit/32956e0f49ae358aea5212f4de689cfaa8431155))


### Improvements

* **audio:** remove AudioRecorder.swift, wire Rust FfiAudioCapture ([70b4170](https://github.com/IlyaGulya/wrenflow/commit/70b417090aa1cffabfaf1d23d18459c276de364f))
* **ffi:** persist history in Rust directly, remove Swift FFI fallbacks ([c5db1e4](https://github.com/IlyaGulya/wrenflow/commit/c5db1e4abb476077781064642babbb8c25179129))
