# Changelog

## [0.3.0](https://github.com/IlyaGulya/wrenflow/compare/v0.2.0...v0.3.0) (2026-04-02)


### New Features

* add audio actor with cpal capture and level signals ([e5fa6fb](https://github.com/IlyaGulya/wrenflow/commit/e5fa6fb9a3123a94e8dfc83f8d42596b11f14935))
* add Flutter dev workflow justfile ([7719a29](https://github.com/IlyaGulya/wrenflow/commit/7719a297532364f51456efd037f046877b090fb1))
* add history actor with SQLite store and rinf signals ([e7c962d](https://github.com/IlyaGulya/wrenflow/commit/e7c962d86cecb1ada9d36405719c1730c19347ac))
* add history panel screen with list, delete, clear ([c5cb82d](https://github.com/IlyaGulya/wrenflow/commit/c5cb82d8844e4abc2a182eafa44d33a4b872559b))
* add hotkey (rdev) and paste (enigo+arboard) actors ([1928bf6](https://github.com/IlyaGulya/wrenflow/commit/1928bf6b209c5fcc983976827b440ffe9e6bf3fd))
* add recording overlay with waveform visualization ([c254a8a](https://github.com/IlyaGulya/wrenflow/commit/c254a8a25982bbd330df175da480d7b432137355))
* add Rust logging via eprintln + panic hook with crash file ([8a43f8b](https://github.com/IlyaGulya/wrenflow/commit/8a43f8b9391fc4cadac55bfd0a32b6f0d9c3219d))
* add setup wizard, model download UI, launch at login ([c8e2244](https://github.com/IlyaGulya/wrenflow/commit/c8e2244d91c3ddcaa30792f5325c4ad018f0939f))
* add system tray, settings, permissions polling, model actor ([7e05fa0](https://github.com/IlyaGulya/wrenflow/commit/7e05fa05e35f096e799d24abd6fe25b4b94300a1))
* add update service and provider for GitHub release checks ([db399cf](https://github.com/IlyaGulya/wrenflow/commit/db399cfa670d09cb4cce8511d8f3105768221a28))
* app lifecycle state machine + multi-window + model/pipeline fixes ([c6850d8](https://github.com/IlyaGulya/wrenflow/commit/c6850d85fa2a009572fa354485d32025722cc10b))
* auto-update UI, fix pipeline timers, SVG icon generation ([2defe90](https://github.com/IlyaGulya/wrenflow/commit/2defe903039bf183c8d691b2e48d7c54750f84ae))
* CGEvent paste, tray menu, app icon, TCC fix, dual logging ([cca596e](https://github.com/IlyaGulya/wrenflow/commit/cca596eaed47da765948c2f5c8bf151fa64461de))
* custom hotkey capture + default mic name in settings ([93d7937](https://github.com/IlyaGulya/wrenflow/commit/93d7937a706b708cce68b7ae711fbcb86745474e))
* decouple paste from pipeline, fix tray, transcript test improvements ([cb34e77](https://github.com/IlyaGulya/wrenflow/commit/cb34e77c6c5b4810276855ddcd490251d6afb594))
* define all rinf signals for Flutter↔Rust communication ([552c258](https://github.com/IlyaGulya/wrenflow/commit/552c2583d6468d7f6f8c31f2eace8a594a184fa8))
* enhance tray menu with version and microphone selection ([b51b367](https://github.com/IlyaGulya/wrenflow/commit/b51b367bf80bc4e3905d3caf7caaf13c6c838d9e))
* error toast notifications + on-demand device refresh ([3d64cb4](https://github.com/IlyaGulya/wrenflow/commit/3d64cb43c0431bad18200c58a348516ecbe82350))
* error toast notifications + on-demand device refresh ([a6fefec](https://github.com/IlyaGulya/wrenflow/commit/a6fefec8ff8bbb64b439f2185c8b11402aed13c7))
* expandable history entries with metrics + app icon in Settings ([72307a9](https://github.com/IlyaGulya/wrenflow/commit/72307a94bc69caed512dfcdd0ddd83e6ab77d6d6))
* implement hub main.rs with tokio runtime and pipeline actor ([7b5ee50](https://github.com/IlyaGulya/wrenflow/commit/7b5ee50ca71d2c861272291f0077876b07d457d0))
* migrate to XcodeGen + mise tasks, proper signing ([d9abf61](https://github.com/IlyaGulya/wrenflow/commit/d9abf61215ea8b4e49bdb781ac93c28d23879dd2))
* native recording overlay via NSPanel + platform channel ([9e1a574](https://github.com/IlyaGulya/wrenflow/commit/9e1a5742744accef42aa5440a2b53c851952380a))
* pixel-perfect UI port from Swift WrenflowStyle to Flutter ([805acbe](https://github.com/IlyaGulya/wrenflow/commit/805acbe0aaa7acf50585fcb14e1bf936012f73e4))
* prewarm Parakeet TDT model on startup ([d895874](https://github.com/IlyaGulya/wrenflow/commit/d895874a69027cb9b258b9f7e5c62b07dd9c115a))
* redesign setup wizard as minimal floating card ([f08dadf](https://github.com/IlyaGulya/wrenflow/commit/f08dadffa225575402c7b8ffb601cbec19c793e2))
* replace rdev with raw-input, add stderr logging + panic hook ([2973007](https://github.com/IlyaGulya/wrenflow/commit/2973007c5aeee5477eaef1b44e820a82a00208ea))
* save recordings as OGG/Opus, use dirs crate for paths ([048ad12](https://github.com/IlyaGulya/wrenflow/commit/048ad12f5cf4c3cabf0c59dbfe4cc42185d7fb38))
* scaffold Flutter+rinf project and simplify pipeline for migration ([c0c6a0d](https://github.com/IlyaGulya/wrenflow/commit/c0c6a0df01391e30fa6e37509b511a21f3eccaad))
* tray icon from bird SVG, generate all icons at build time ([f342b05](https://github.com/IlyaGulya/wrenflow/commit/f342b05321fd0536baf29c891999ca125a4d7cee))
* upgrade to Flutter 3.41.6, add Riverpod + permissions + local-only ([e7ef734](https://github.com/IlyaGulya/wrenflow/commit/e7ef734717209a999bf10c4f0bd404194f81f953))
* wire local transcription (Parakeet) to pipeline ([5cd01fc](https://github.com/IlyaGulya/wrenflow/commit/5cd01fc019e793454e248e170a53d8f4751ab152))
* wire pipeline FSM timers to rinf signal routing ([468e5d0](https://github.com/IlyaGulya/wrenflow/commit/468e5d05e0598318a456faa5d36f7f9861bdc9f7))


### Bug Fixes

* app icon not showing in Dock — set CFBundleIconFile + CFBundleIconName ([6b9cda8](https://github.com/IlyaGulya/wrenflow/commit/6b9cda89b4741cc2330c0998790ec4d520c5344e))
* app startup crash (rdev thread), window style, Wrenflow theme ([e38bb09](https://github.com/IlyaGulya/wrenflow/commit/e38bb096b03c2953f35cd586b3ef03f5a1279bb6))
* bundle ONNX Runtime dylib — resolves model loading deadlock ([0085bb0](https://github.com/IlyaGulya/wrenflow/commit/0085bb05d79644b0ab339fe66da300e0e812c746))
* **ci:** create assets directories before icon generation ([bd27128](https://github.com/IlyaGulya/wrenflow/commit/bd271286143df474662e4079bed3e6103185b501))
* **ci:** enable hardened runtime, fix notarization ([aace23a](https://github.com/IlyaGulya/wrenflow/commit/aace23a6495cb494a13f45148231de06f30a0650))
* **ci:** generate xcodeproj + xcworkspace before flutter build ([6bdfe4f](https://github.com/IlyaGulya/wrenflow/commit/6bdfe4f89d6e06c526cc45d4335b705843538c6e))
* **ci:** secure timestamp, concurrency groups, bump all actions ([8d1c7d8](https://github.com/IlyaGulya/wrenflow/commit/8d1c7d8a7a2c6b17c366697adbdb1ebc5498cc87))
* **ci:** use xcworkspace stub instead of pod install in xcodegen ([97f0833](https://github.com/IlyaGulya/wrenflow/commit/97f0833086ea6c38cab9fbd4baac8a427a8117aa))
* defer microphone device listing until after setup wizard ([7239f79](https://github.com/IlyaGulya/wrenflow/commit/7239f79a2988315658dc15eed25459b2fd2dd464))
* link libwrenflow_ffi.a directly instead of -l flag (prevents dylib preference) ([425580d](https://github.com/IlyaGulya/wrenflow/commit/425580debf44159e02d003df286cb26f86baf5e7))
* persist history to SQLite + migrate legacy schema ([0263d87](https://github.com/IlyaGulya/wrenflow/commit/0263d87207dfd4c217897300e6909c0b944a2ce0))
* prevent dock icon flash on startup ([03a0272](https://github.com/IlyaGulya/wrenflow/commit/03a0272dce75b9edd11df6502e2dd197353a928d))
* resolve ONNX duplicate symbol linker error with load-dynamic ([e5a539d](https://github.com/IlyaGulya/wrenflow/commit/e5a539d1dd715807242016fd417b2b9b9b48c3de))
* unify wizard permissions with PermissionStateObservable ([3e03a40](https://github.com/IlyaGulya/wrenflow/commit/3e03a40914a948040db33ecf04eb216df1d78581))
* use macos_window_utils for window, surface bg instead of transparency ([f3953f7](https://github.com/IlyaGulya/wrenflow/commit/f3953f77435bb4014530ac0c9d83f772d9109b66))


### Performance

* transcribe from memory buffer, write WAV in parallel ([7a8f30a](https://github.com/IlyaGulya/wrenflow/commit/7a8f30a97cbe886d04d5bacd9c0d0208ce49343d))


### Improvements

* generate Info.plist from XcodeGen project.yml ([d71d7fd](https://github.com/IlyaGulya/wrenflow/commit/d71d7fd6dd7fcaa226559e3ef6e23a52feaeff8a))
* move History into Settings as a tab ([f7efa52](https://github.com/IlyaGulya/wrenflow/commit/f7efa5227a0f2920ff25ded55a8bf92e94d14edc))
* remove all cloud transcription (Groq), go local-only ([f142b79](https://github.com/IlyaGulya/wrenflow/commit/f142b7994b31a483b5ae95f9956a7481511191ed))
* remove desktop_multi_window, single Flutter engine ([fe25978](https://github.com/IlyaGulya/wrenflow/commit/fe2597803980846d3191f93979d8aa948ef781da))
* remove old Swift app, flatten Flutter to root ([53fd306](https://github.com/IlyaGulya/wrenflow/commit/53fd3062a6a3b2c17decbae59b1e7ea6ae54b45c))

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
