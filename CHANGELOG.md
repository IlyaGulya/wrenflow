# Changelog

## [0.5.0](https://github.com/IlyaGulya/wrenflow/compare/v0.4.0...v0.5.0) (2026-08-13)


### ⚠ BREAKING CHANGES

* replace Flutter desktop with native GPUI app

### New Features

* add alternative base url setting ([1136d58](https://github.com/IlyaGulya/wrenflow/commit/1136d58a7e8eb07d5e538cc105b151b30cab9051))
* add audio actor with cpal capture and level signals ([e5fa6fb](https://github.com/IlyaGulya/wrenflow/commit/e5fa6fb9a3123a94e8dfc83f8d42596b11f14935))
* add Flutter dev workflow justfile ([7719a29](https://github.com/IlyaGulya/wrenflow/commit/7719a297532364f51456efd037f046877b090fb1))
* add history actor with SQLite store and rinf signals ([e7c962d](https://github.com/IlyaGulya/wrenflow/commit/e7c962d86cecb1ada9d36405719c1730c19347ac))
* add history panel screen with list, delete, clear ([c5cb82d](https://github.com/IlyaGulya/wrenflow/commit/c5cb82d8844e4abc2a182eafa44d33a4b872559b))
* add hotkey (rdev) and paste (enigo+arboard) actors ([1928bf6](https://github.com/IlyaGulya/wrenflow/commit/1928bf6b209c5fcc983976827b440ffe9e6bf3fd))
* add launch at login controls ([abd1e68](https://github.com/IlyaGulya/wrenflow/commit/abd1e6867cc0a1f8f58b8ec5f18d0c6c637a5b24))
* add local whisper model management flow ([d2be32e](https://github.com/IlyaGulya/wrenflow/commit/d2be32eefa18d55b20ffde44230878185794bc75))
* add recording overlay with waveform visualization ([c254a8a](https://github.com/IlyaGulya/wrenflow/commit/c254a8a25982bbd330df175da480d7b432137355))
* add Rust logging via eprintln + panic hook with crash file ([8a43f8b](https://github.com/IlyaGulya/wrenflow/commit/8a43f8b9391fc4cadac55bfd0a32b6f0d9c3219d))
* add setup wizard, model download UI, launch at login ([c8e2244](https://github.com/IlyaGulya/wrenflow/commit/c8e2244d91c3ddcaa30792f5325c4ad018f0939f))
* add system tray, settings, permissions polling, model actor ([7e05fa0](https://github.com/IlyaGulya/wrenflow/commit/7e05fa05e35f096e799d24abd6fe25b4b94300a1))
* add update service and provider for GitHub release checks ([db399cf](https://github.com/IlyaGulya/wrenflow/commit/db399cfa670d09cb4cce8511d8f3105768221a28))
* app lifecycle state machine + multi-window + model/pipeline fixes ([c6850d8](https://github.com/IlyaGulya/wrenflow/commit/c6850d85fa2a009572fa354485d32025722cc10b))
* **audio:** add cross-platform AudioCapture using cpal ([fbd2e31](https://github.com/IlyaGulya/wrenflow/commit/fbd2e314bb8fa2a5c0b6b02605de485ebffb2600))
* auto-update UI, fix pipeline timers, SVG icon generation ([2defe90](https://github.com/IlyaGulya/wrenflow/commit/2defe903039bf183c8d691b2e48d7c54750f84ae))
* CGEvent paste, tray menu, app icon, TCC fix, dual logging ([cca596e](https://github.com/IlyaGulya/wrenflow/commit/cca596eaed47da765948c2f5c8bf151fa64461de))
* custom hotkey capture + default mic name in settings ([93d7937](https://github.com/IlyaGulya/wrenflow/commit/93d7937a706b708cce68b7ae711fbcb86745474e))
* decouple paste from pipeline, fix tray, transcript test improvements ([cb34e77](https://github.com/IlyaGulya/wrenflow/commit/cb34e77c6c5b4810276855ddcd490251d6afb594))
* define all rinf signals for Flutter↔Rust communication ([552c258](https://github.com/IlyaGulya/wrenflow/commit/552c2583d6468d7f6f8c31f2eace8a594a184fa8))
* dynamically get the notch size ([c5d0f29](https://github.com/IlyaGulya/wrenflow/commit/c5d0f29ccd7d1d5c6ecb871c1221afe1108b8407))
* dynamically get the notch size ([3e81bae](https://github.com/IlyaGulya/wrenflow/commit/3e81baefbde847102ef52af91fbdb11a0a4e2bf5))
* enhance tray menu with version and microphone selection ([b51b367](https://github.com/IlyaGulya/wrenflow/commit/b51b367bf80bc4e3905d3caf7caaf13c6c838d9e))
* error toast notifications + on-demand device refresh ([3d64cb4](https://github.com/IlyaGulya/wrenflow/commit/3d64cb43c0431bad18200c58a348516ecbe82350))
* error toast notifications + on-demand device refresh ([a6fefec](https://github.com/IlyaGulya/wrenflow/commit/a6fefec8ff8bbb64b439f2185c8b11402aed13c7))
* expandable history entries with metrics + app icon in Settings ([72307a9](https://github.com/IlyaGulya/wrenflow/commit/72307a94bc69caed512dfcdd0ddd83e6ab77d6d6))
* **ffi:** expose Groq models fetching via FFI, replace Swift HTTP calls ([3c56e23](https://github.com/IlyaGulya/wrenflow/commit/3c56e23c1adf1986eaf1604e8066f0e47b8273b6))
* **ffi:** expose HistoryStore via FFI, replace CoreData with Rust SQLite ([7265b1f](https://github.com/IlyaGulya/wrenflow/commit/7265b1fb98ccd2514ceb487baf56ec112cbcc353))
* **ffi:** expose post-processing via FFI, replace Swift HTTP calls ([6096e7a](https://github.com/IlyaGulya/wrenflow/commit/6096e7a0f8390cabfac3081877810f264e53dfe7))
* go local-first, remove cloud transcription, restructure settings ([5e99ff2](https://github.com/IlyaGulya/wrenflow/commit/5e99ff2634fa9640c0972a908557d052fb46ce69))
* implement hub main.rs with tokio runtime and pipeline actor ([7b5ee50](https://github.com/IlyaGulya/wrenflow/commit/7b5ee50ca71d2c861272291f0077876b07d457d0))
* make the ui more idomatically swift ([24adc13](https://github.com/IlyaGulya/wrenflow/commit/24adc13b709ca36ad8c2e4501c3625b23f33daf1))
* migrate to XcodeGen + mise tasks, proper signing ([d9abf61](https://github.com/IlyaGulya/wrenflow/commit/d9abf61215ea8b4e49bdb781ac93c28d23879dd2))
* move launch at login state into rust snapshot ([ba53dea](https://github.com/IlyaGulya/wrenflow/commit/ba53deae85acb2db54b38345f62e3e179a39f4e4))
* move update status into rust snapshot ([4db442f](https://github.com/IlyaGulya/wrenflow/commit/4db442f40cd42802cd7dee0ea71854463a76dfc1))
* native recording overlay via NSPanel + platform channel ([9e1a574](https://github.com/IlyaGulya/wrenflow/commit/9e1a5742744accef42aa5440a2b53c851952380a))
* new app icon, updated README, version injection from Cargo.toml ([769a8c2](https://github.com/IlyaGulya/wrenflow/commit/769a8c27acff8b0d50aeff89149483636b3a302c))
* pixel-perfect UI port from Swift WrenflowStyle to Flutter ([805acbe](https://github.com/IlyaGulya/wrenflow/commit/805acbe0aaa7acf50585fcb14e1bf936012f73e4))
* prewarm Parakeet TDT model on startup ([d895874](https://github.com/IlyaGulya/wrenflow/commit/d895874a69027cb9b258b9f7e5c62b07dd9c115a))
* productionize the native GPUI app ([a33557d](https://github.com/IlyaGulya/wrenflow/commit/a33557d920a6b145ef34d9f8570a93b36f2a00c7))
* redesign setup wizard as minimal floating card ([f08dadf](https://github.com/IlyaGulya/wrenflow/commit/f08dadffa225575402c7b8ffb601cbec19c793e2))
* replace Flutter desktop with native GPUI app ([7bdb8c5](https://github.com/IlyaGulya/wrenflow/commit/7bdb8c5a46e6893b04adfbd11516c3b289deadd7))
* replace rdev with raw-input, add stderr logging + panic hook ([2973007](https://github.com/IlyaGulya/wrenflow/commit/2973007c5aeee5477eaef1b44e820a82a00208ea))
* report shell capabilities through rust ([9664c48](https://github.com/IlyaGulya/wrenflow/commit/9664c4887aa4d8477160b80bace8aec5b90ffebd))
* save recordings as OGG/Opus, use dirs crate for paths ([048ad12](https://github.com/IlyaGulya/wrenflow/commit/048ad12f5cf4c3cabf0c59dbfe4cc42185d7fb38))
* scaffold Flutter+rinf project and simplify pipeline for migration ([c0c6a0d](https://github.com/IlyaGulya/wrenflow/commit/c0c6a0df01391e30fa6e37509b511a21f3eccaad))
* surface runtime capability snapshot ([833de5f](https://github.com/IlyaGulya/wrenflow/commit/833de5f6ffd63f155f29a0ff83beba85451be54e))
* tray icon from bird SVG, generate all icons at build time ([f342b05](https://github.com/IlyaGulya/wrenflow/commit/f342b05321fd0536baf29c891999ca125a4d7cee))
* **ui:** borderless settings with transparent titlebar ([156908a](https://github.com/IlyaGulya/wrenflow/commit/156908a191393ade4f648e369051f057c7e1f24b))
* **ui:** show PermissionGateView when permissions missing on hotkey ([de09f6d](https://github.com/IlyaGulya/wrenflow/commit/de09f6d47c47c118acef731d142cca4916b373fc))
* upgrade to Flutter 3.41.6, add Riverpod + permissions + local-only ([e7ef734](https://github.com/IlyaGulya/wrenflow/commit/e7ef734717209a999bf10c4f0bd404194f81f953))
* wire local transcription (Parakeet) to pipeline ([5cd01fc](https://github.com/IlyaGulya/wrenflow/commit/5cd01fc019e793454e248e170a53d8f4751ab152))
* wire pipeline FSM timers to rinf signal routing ([468e5d0](https://github.com/IlyaGulya/wrenflow/commit/468e5d05e0598318a456faa5d36f7f9861bdc9f7))


### Bug Fixes

* add light/dark SVG variants for README ([62000df](https://github.com/IlyaGulya/wrenflow/commit/62000df5135ccb87a2d8cd6010f967aa59cc1023))
* align verified model timing evidence ([877c9d8](https://github.com/IlyaGulya/wrenflow/commit/877c9d8b504b5ba9415a2e2545b480de5f03b6f5))
* app icon not showing in Dock — set CFBundleIconFile + CFBundleIconName ([6b9cda8](https://github.com/IlyaGulya/wrenflow/commit/6b9cda89b4741cc2330c0998790ec4d520c5344e))
* app startup crash (rdev thread), window style, Wrenflow theme ([e38bb09](https://github.com/IlyaGulya/wrenflow/commit/e38bb096b03c2953f35cd586b3ef03f5a1279bb6))
* bind release evidence to exact source commit ([a818273](https://github.com/IlyaGulya/wrenflow/commit/a81827311a8aa5745a88e1f4a081746ce820a6f5))
* **build:** fix release build, arm64 only, conditional linker settings ([50deb9e](https://github.com/IlyaGulya/wrenflow/commit/50deb9e289d6b3921fdafed776d050433b15b0f6))
* bundle ONNX Runtime dylib — resolves model loading deadlock ([0085bb0](https://github.com/IlyaGulya/wrenflow/commit/0085bb05d79644b0ab339fe66da300e0e812c746))
* canonicalize performance cadence evidence ([c1d1d9d](https://github.com/IlyaGulya/wrenflow/commit/c1d1d9d4c5233e4957d8db55919572ef7dd07763))
* **ci:** add binary size check, debug Rust FFI linking ([045ef8a](https://github.com/IlyaGulya/wrenflow/commit/045ef8a0e38341ab1d2b308e865c7fbe53c0cf64))
* **ci:** beta versions use next minor from last release tag ([14301e0](https://github.com/IlyaGulya/wrenflow/commit/14301e05babec569ee7bb90bd02e1412af5eac58))
* **ci:** clean Swift .build before release to prevent stale cache ([7382123](https://github.com/IlyaGulya/wrenflow/commit/7382123f8b77137a6e27d5343752b7c87e065cb6))
* **ci:** create assets directories before icon generation ([bd27128](https://github.com/IlyaGulya/wrenflow/commit/bd271286143df474662e4079bed3e6103185b501))
* **ci:** drop x86_64 target, ort-sys lacks prebuilt binaries for it ([2bfaec5](https://github.com/IlyaGulya/wrenflow/commit/2bfaec59fff4775d6c03d7320df55c759f2ad947))
* **ci:** enable cache-workspace-crates to preserve libwrenflow_ffi.a ([d96104d](https://github.com/IlyaGulya/wrenflow/commit/d96104dd1702acdb2ce435ef45e63fcfd8ccc5e8))
* **ci:** enable hardened runtime, fix notarization ([aace23a](https://github.com/IlyaGulya/wrenflow/commit/aace23a6495cb494a13f45148231de06f30a0650))
* **ci:** fix action-semantic-pull-request SHA pin ([ab2d7ce](https://github.com/IlyaGulya/wrenflow/commit/ab2d7ce1a814c2d05d40f01268d6e8ef37050261))
* **ci:** fix ghalint download URL ([11044fd](https://github.com/IlyaGulya/wrenflow/commit/11044fd9ac99502d1d094403c0f529770d3724dc))
* **ci:** fix ghalint version, use actionlint download script ([a752ae8](https://github.com/IlyaGulya/wrenflow/commit/a752ae877b0e2536f85fd29b27f4f1d81cdc620f))
* **ci:** generate xcodeproj + xcworkspace before flutter build ([6bdfe4f](https://github.com/IlyaGulya/wrenflow/commit/6bdfe4f89d6e06c526cc45d4335b705843538c6e))
* **ci:** invalidate rust cache, remove ad-hoc fallback, clean up diagnostics ([958e603](https://github.com/IlyaGulya/wrenflow/commit/958e60364ccc639bee8bc1987f43c331212f705f))
* **ci:** keep verbose swift build, show binary sizes ([d5def47](https://github.com/IlyaGulya/wrenflow/commit/d5def47967b5624834c7e4700c02a7e5fb4408d1))
* **ci:** remove redundant CLI build, fix create-dmg on headless CI ([06823ec](https://github.com/IlyaGulya/wrenflow/commit/06823ecf4b91fc4ded8e73b7c6a8275523faa69b))
* **ci:** remove unused PATCH variable (shellcheck) ([83e49fb](https://github.com/IlyaGulya/wrenflow/commit/83e49fb0b1ea819f8226f5d77aa8a247cd58e929))
* **ci:** rename CLI to wrenflow-cli in bundle (case-insensitive FS collision) ([33c77f3](https://github.com/IlyaGulya/wrenflow/commit/33c77f3badc3b7b1a71994f42ba058a8c95f580e))
* **ci:** rename Xcode step, make skip check unconditional ([502605b](https://github.com/IlyaGulya/wrenflow/commit/502605bdf4a00190c72bb57489f3fdf34afac6e5))
* **ci:** secure timestamp, concurrency groups, bump all actions ([8d1c7d8](https://github.com/IlyaGulya/wrenflow/commit/8d1c7d8a7a2c6b17c366697adbdb1ebc5498cc87))
* **ci:** sign CLI binary for notarization, notarize betas too, log errors ([3c47a4d](https://github.com/IlyaGulya/wrenflow/commit/3c47a4d2724774b3b661bb49847b56d8749e5f75))
* **ci:** stable-only tag lookup for beta, lint hooks, release-please SHA pin ([1016cc0](https://github.com/IlyaGulya/wrenflow/commit/1016cc0e939b6e7e28499a36f3cd3c6c8dd3fb42))
* **ci:** use action-semantic-pull-request v6.1.1 ([15c0151](https://github.com/IlyaGulya/wrenflow/commit/15c0151f5fc9b265c4bbb0174a64ff37488a298a))
* **ci:** use Xcode 26.3 (matches local dev environment) ([09ae69d](https://github.com/IlyaGulya/wrenflow/commit/09ae69d8d23f15e02726895f23098fad66bff510))
* **ci:** use xcworkspace stub instead of pod install in xcodegen ([97f0833](https://github.com/IlyaGulya/wrenflow/commit/97f0833086ea6c38cab9fbd4baac8a427a8117aa))
* correlate active performance samples ([772c2e9](https://github.com/IlyaGulya/wrenflow/commit/772c2e99e5f19de4528eda255d5f39c763f24306))
* defer microphone device listing until after setup wizard ([7239f79](https://github.com/IlyaGulya/wrenflow/commit/7239f79a2988315658dc15eed25459b2fd2dd464))
* enable the pinned license CLI ([dc73067](https://github.com/IlyaGulya/wrenflow/commit/dc73067fc99f265d11f5b20927ffd17db5724d90))
* **ffi:** fix duplicate thiserror dep, regenerate UniFFI bindings ([fe9f876](https://github.com/IlyaGulya/wrenflow/commit/fe9f876afaec63d53d5a5842e2b08031e5f07a8a))
* **ffi:** fix history persistence, remove CoreData, hide disabled steps ([6ed225a](https://github.com/IlyaGulya/wrenflow/commit/6ed225ad8f4bc6cf62ce5d6a9d7dfbe8a7fa25d0))
* harden local model activation flow ([f3cee23](https://github.com/IlyaGulya/wrenflow/commit/f3cee231c6844d3bbaf23ddfb50493066a3fb324))
* invoke pinned supply chain tools directly ([603162e](https://github.com/IlyaGulya/wrenflow/commit/603162eb47a77c650f803a40139262cac1d0af82))
* keep menu bar startup independent of hardware ([0045a24](https://github.com/IlyaGulya/wrenflow/commit/0045a24c251e7f87e7ac0d3bc32050cd13f4de4f))
* keep wakeup samples self-consistent ([6840449](https://github.com/IlyaGulya/wrenflow/commit/6840449a98d4639034c9b7c03b1d74a725dededb))
* link libwrenflow_ffi.a directly instead of -l flag (prevents dylib preference) ([425580d](https://github.com/IlyaGulya/wrenflow/commit/425580debf44159e02d003df286cb26f86baf5e7))
* make idle sampling cadence-aware ([3a2217b](https://github.com/IlyaGulya/wrenflow/commit/3a2217b1c1b8624d49b23951f7ca75f5d553fc4c))
* make performance readiness route-aware ([cdb85f3](https://github.com/IlyaGulya/wrenflow/commit/cdb85f3bad093e9c82d713df0ed66152998762de))
* persist history to SQLite + migrate legacy schema ([0263d87](https://github.com/IlyaGulya/wrenflow/commit/0263d87207dfd4c217897300e6909c0b944a2ce0))
* persist hotkey and correct startup/version behavior ([53f2d9c](https://github.com/IlyaGulya/wrenflow/commit/53f2d9c5699cb24ad82a9d6b81e466951f2f4347))
* pin release workflow search tooling ([3447c27](https://github.com/IlyaGulya/wrenflow/commit/3447c27555705de3a8a3d2e72204c83ba89fadb8))
* polish macos launch and update UX ([d9148d0](https://github.com/IlyaGulya/wrenflow/commit/d9148d023735b1373813e133ef276c3c46a6680e))
* polish macos model and startup flows ([d009030](https://github.com/IlyaGulya/wrenflow/commit/d009030ff33fa79d3fb4f53cac2dc31e199c7525))
* prepare Rust before parallel CI tasks ([c2107bb](https://github.com/IlyaGulya/wrenflow/commit/c2107bbdcc410081fe072e34407c8056256a8673))
* prevent dock icon flash on startup ([03a0272](https://github.com/IlyaGulya/wrenflow/commit/03a0272dce75b9edd11df6502e2dd197353a928d))
* publish beta release with explicit repository context ([65f2227](https://github.com/IlyaGulya/wrenflow/commit/65f222758ae1324fac0744dd888b28bbf3efdd17))
* resolve ONNX duplicate symbol linker error with load-dynamic ([e5a539d](https://github.com/IlyaGulya/wrenflow/commit/e5a539d1dd715807242016fd417b2b9b9b48c3de))
* stabilize release performance gates ([05ed860](https://github.com/IlyaGulya/wrenflow/commit/05ed8609ce23d2a9c5b39e6917a13dbd1f0dbc8d))
* stage tagless private release drafts ([aa95433](https://github.com/IlyaGulya/wrenflow/commit/aa95433cd50c98679e2b5407cdba4196b42978e2))
* typed errors, audio format fix, settings polish ([4643324](https://github.com/IlyaGulya/wrenflow/commit/46433243e54b94f92224d986bede1fcb4fcc1ea5))
* **ui:** error toast, audio crash fix, settings polish ([f88030d](https://github.com/IlyaGulya/wrenflow/commit/f88030d83bf39c5272d62f1da4666c5d431f3f3e))
* **ui:** fix permissions flow, remove Requesting state, fix polling ([32956e0](https://github.com/IlyaGulya/wrenflow/commit/32956e0f49ae358aea5212f4de689cfaa8431155))
* unify wizard permissions with PermissionStateObservable ([3e03a40](https://github.com/IlyaGulya/wrenflow/commit/3e03a40914a948040db33ecf04eb216df1d78581))
* use macos_window_utils for window, surface bg instead of transparency ([f3953f7](https://github.com/IlyaGulya/wrenflow/commit/f3953f77435bb4014530ac0c9d83f772d9109b66))
* use one supply chain tool environment ([eacc739](https://github.com/IlyaGulya/wrenflow/commit/eacc7396f093c5594d701d782d68d8bca5581f28))
* verify existing private release drafts ([6e83bb5](https://github.com/IlyaGulya/wrenflow/commit/6e83bb5f15855fb76611a2068efd58ec8cd4aa57))


### Performance

* embed GPUI Metal shaders at build time ([42ece32](https://github.com/IlyaGulya/wrenflow/commit/42ece32dc9013b13d945b1cb8fd436626073dda7))
* keep menu bar idle work event-driven ([dec7c02](https://github.com/IlyaGulya/wrenflow/commit/dec7c0233d3aba746517199b92b9649342c250d4))
* make cold launch evidence deterministic ([f19c32c](https://github.com/IlyaGulya/wrenflow/commit/f19c32c55118f675e5915269198d0252f11e56b9))
* make launch readiness deterministic ([cdd4ab6](https://github.com/IlyaGulya/wrenflow/commit/cdd4ab66b7510943c3186893041faa4a3e566f8b))
* overlap permission discovery with cold startup ([1ee7508](https://github.com/IlyaGulya/wrenflow/commit/1ee7508d3444d47475fae5e1a833e1a62e8b875d))
* transcribe from memory buffer, write WAV in parallel ([7a8f30a](https://github.com/IlyaGulya/wrenflow/commit/7a8f30a97cbe886d04d5bacd9c0d0208ce49343d))


### Improvements

* add auto-disposed wizard draft state ([8ad413d](https://github.com/IlyaGulya/wrenflow/commit/8ad413dc4b8b42a6e8ea45499faedde9e6faf0f1))
* add base dart snapshot notifier ([5930da9](https://github.com/IlyaGulya/wrenflow/commit/5930da9a7a1c677513a1e2f374faed3b23d80890))
* **audio:** remove AudioRecorder.swift, wire Rust FfiAudioCapture ([70b4170](https://github.com/IlyaGulya/wrenflow/commit/70b417090aa1cffabfaf1d23d18459c276de364f))
* bootstrap shell bridges explicitly ([ef4493c](https://github.com/IlyaGulya/wrenflow/commit/ef4493c6355efb5dc66033b45a6931c60b2c41f2))
* centralize runtime config updates in rust ([53a993d](https://github.com/IlyaGulya/wrenflow/commit/53a993df2e8798c0d48c6f9b9a9855bbee1a8266))
* **ci:** rewrite justfile with self-contained build/release recipes ([9b67b17](https://github.com/IlyaGulya/wrenflow/commit/9b67b171679a7d7ce8843ac5bcbe13e8854aba91))
* derive settings and wizard presentation ([a1ad428](https://github.com/IlyaGulya/wrenflow/commit/a1ad42851f8042ba4b8e6e433fba37a2d7dda489))
* derive settings tab presentation ([b618661](https://github.com/IlyaGulya/wrenflow/commit/b61866138ef20f7fb6d676fa864cd1fc450a18df))
* derive shell capabilities from adapters ([6fdd2fd](https://github.com/IlyaGulya/wrenflow/commit/6fdd2fdaeda977501b94e8b3865349cad8ecc872))
* derive shell pipeline presentation ([52610d8](https://github.com/IlyaGulya/wrenflow/commit/52610d86ea70664fadeea9c09c80c3f161978b7c))
* derive tray and wizard presentation state ([e9cadb0](https://github.com/IlyaGulya/wrenflow/commit/e9cadb0620b55ab9750d101ab4492ac072044ccc))
* extract shared snapshot bridge helpers ([6a1ad12](https://github.com/IlyaGulya/wrenflow/commit/6a1ad129b19c2fe630f091c3209b1c7f4ce7b8a8))
* fan out runtime config from rust settings runtime ([680929d](https://github.com/IlyaGulya/wrenflow/commit/680929d858edbf697a3254e3739348d41ad56a92))
* **ffi:** persist history in Rust directly, remove Swift FFI fallbacks ([c5db1e4](https://github.com/IlyaGulya/wrenflow/commit/c5db1e4abb476077781064642babbb8c25179129))
* generate Info.plist from XcodeGen project.yml ([d71d7fd](https://github.com/IlyaGulya/wrenflow/commit/d71d7fd6dd7fcaa226559e3ef6e23a52feaeff8a))
* isolate rust platform backends ([e4660d7](https://github.com/IlyaGulya/wrenflow/commit/e4660d7e878965a48cea2d95019be4dc1af0a203))
* isolate shell platform adapters ([e8f14ee](https://github.com/IlyaGulya/wrenflow/commit/e8f14eedc6b94afef831daccdc293147ae18835b))
* isolate tray shell adapter ([fb873f1](https://github.com/IlyaGulya/wrenflow/commit/fb873f19ba7dcb4d4293b5d0c56c89ea64bcb7c5))
* isolate window shell adapter ([d17ccd6](https://github.com/IlyaGulya/wrenflow/commit/d17ccd691c4b6eb5f87a09eaa101bf452aa90f6f))
* keep tray window actions state-driven ([3096cc9](https://github.com/IlyaGulya/wrenflow/commit/3096cc9d91ad9296797240a7d0a10ae85a594aa7))
* move History into Settings as a tab ([f7efa52](https://github.com/IlyaGulya/wrenflow/commit/f7efa5227a0f2920ff25ded55a8bf92e94d14edc))
* move runtime state behind rust snapshots ([3b9d02a](https://github.com/IlyaGulya/wrenflow/commit/3b9d02a95d9681f40e074fa11232cb9cb917e940))
* move settings persistence into rust ([f0fc974](https://github.com/IlyaGulya/wrenflow/commit/f0fc9749935afc23b6dd5de80c483b418c45cfd3))
* remove all cloud transcription (Groq), go local-only ([f142b79](https://github.com/IlyaGulya/wrenflow/commit/f142b7994b31a483b5ae95f9956a7481511191ed))
* remove desktop_multi_window, single Flutter engine ([fe25978](https://github.com/IlyaGulya/wrenflow/commit/fe2597803980846d3191f93979d8aa948ef781da))
* remove hidden runtime defaults and shell fallbacks ([70da3ba](https://github.com/IlyaGulya/wrenflow/commit/70da3baecab70226a4c46f06d400b268e8d1c60a))
* remove legacy groq settings and infra ([5790f4f](https://github.com/IlyaGulya/wrenflow/commit/5790f4f857434ded1a5980efe8a390b334e971bf))
* remove old Swift app, flatten Flutter to root ([53fd306](https://github.com/IlyaGulya/wrenflow/commit/53fd3062a6a3b2c17decbae59b1e7ea6ae54b45c))
* separate main window shell presentation ([cba1ae0](https://github.com/IlyaGulya/wrenflow/commit/cba1ae032abcba877735cb387f619de298f6dff8))
* simplify selected model action flow ([78b179c](https://github.com/IlyaGulya/wrenflow/commit/78b179c79d0872a163ff4a26f11d2b9d52e9ced1))
* structure actor runtime bootstrap ([af31c00](https://github.com/IlyaGulya/wrenflow/commit/af31c00533bad7ec13bdd75b0d7b12f850c412c9))
* unify CI workflows, semver UpdateManager with mxcl/Version ([f36ccf1](https://github.com/IlyaGulya/wrenflow/commit/f36ccf1a6aee73eeb22dc000bc2fc28aa4fe5030))

## [0.4.0](https://github.com/IlyaGulya/wrenflow/compare/v0.3.0...v0.4.0) (2026-08-12)

Wrenflow 0.4.0 is the first public release of the native GPUI application. It
is a clean install: it does not import or migrate legacy/pre-GPUI data and
makes no backward-compatibility, downgrade, rollback, or beta-to-stable update
promise.

Audio and transcripts stay on the Mac; transcription is local and the app
ships with no telemetry. Read the [Privacy policy](https://github.com/IlyaGulya/wrenflow/blob/e87367e272bc5c3ab5c9519ccd2056297298c079/docs/privacy.md),
[Security policy](https://github.com/IlyaGulya/wrenflow/blob/e87367e272bc5c3ab5c9519ccd2056297298c079/SECURITY.md),
[macOS support contract](https://github.com/IlyaGulya/wrenflow/blob/e87367e272bc5c3ab5c9519ccd2056297298c079/docs/macos-support.md),
[clean-install lifecycle](https://github.com/IlyaGulya/wrenflow/blob/e87367e272bc5c3ab5c9519ccd2056297298c079/docs/gpui-production-lifecycle.md),
and [recovery and support guide](https://github.com/IlyaGulya/wrenflow/blob/e87367e272bc5c3ab5c9519ccd2056297298c079/docs/gpui-recovery.md).


### ⚠ BREAKING CHANGES

* replace Flutter desktop with native GPUI app

### New Features

* add launch at login controls ([abd1e68](https://github.com/IlyaGulya/wrenflow/commit/abd1e6867cc0a1f8f58b8ec5f18d0c6c637a5b24))
* add local whisper model management flow ([d2be32e](https://github.com/IlyaGulya/wrenflow/commit/d2be32eefa18d55b20ffde44230878185794bc75))
* move launch at login state into rust snapshot ([ba53dea](https://github.com/IlyaGulya/wrenflow/commit/ba53deae85acb2db54b38345f62e3e179a39f4e4))
* move update status into rust snapshot ([4db442f](https://github.com/IlyaGulya/wrenflow/commit/4db442f40cd42802cd7dee0ea71854463a76dfc1))
* productionize the native GPUI app ([a33557d](https://github.com/IlyaGulya/wrenflow/commit/a33557d920a6b145ef34d9f8570a93b36f2a00c7))
* replace Flutter desktop with native GPUI app ([7bdb8c5](https://github.com/IlyaGulya/wrenflow/commit/7bdb8c5a46e6893b04adfbd11516c3b289deadd7))
* report shell capabilities through rust ([9664c48](https://github.com/IlyaGulya/wrenflow/commit/9664c4887aa4d8477160b80bace8aec5b90ffebd))
* surface runtime capability snapshot ([833de5f](https://github.com/IlyaGulya/wrenflow/commit/833de5f6ffd63f155f29a0ff83beba85451be54e))


### Bug Fixes

* align verified model timing evidence ([877c9d8](https://github.com/IlyaGulya/wrenflow/commit/877c9d8b504b5ba9415a2e2545b480de5f03b6f5))
* correlate active performance samples ([772c2e9](https://github.com/IlyaGulya/wrenflow/commit/772c2e99e5f19de4528eda255d5f39c763f24306))
* enable the pinned license CLI ([dc73067](https://github.com/IlyaGulya/wrenflow/commit/dc73067fc99f265d11f5b20927ffd17db5724d90))
* harden local model activation flow ([f3cee23](https://github.com/IlyaGulya/wrenflow/commit/f3cee231c6844d3bbaf23ddfb50493066a3fb324))
* invoke pinned supply chain tools directly ([603162e](https://github.com/IlyaGulya/wrenflow/commit/603162eb47a77c650f803a40139262cac1d0af82))
* keep menu bar startup independent of hardware ([0045a24](https://github.com/IlyaGulya/wrenflow/commit/0045a24c251e7f87e7ac0d3bc32050cd13f4de4f))
* keep wakeup samples self-consistent ([6840449](https://github.com/IlyaGulya/wrenflow/commit/6840449a98d4639034c9b7c03b1d74a725dededb))
* make idle sampling cadence-aware ([3a2217b](https://github.com/IlyaGulya/wrenflow/commit/3a2217b1c1b8624d49b23951f7ca75f5d553fc4c))
* make performance readiness route-aware ([cdb85f3](https://github.com/IlyaGulya/wrenflow/commit/cdb85f3bad093e9c82d713df0ed66152998762de))
* persist hotkey and correct startup/version behavior ([53f2d9c](https://github.com/IlyaGulya/wrenflow/commit/53f2d9c5699cb24ad82a9d6b81e466951f2f4347))
* pin release workflow search tooling ([3447c27](https://github.com/IlyaGulya/wrenflow/commit/3447c27555705de3a8a3d2e72204c83ba89fadb8))
* polish macos launch and update UX ([d9148d0](https://github.com/IlyaGulya/wrenflow/commit/d9148d023735b1373813e133ef276c3c46a6680e))
* polish macos model and startup flows ([d009030](https://github.com/IlyaGulya/wrenflow/commit/d009030ff33fa79d3fb4f53cac2dc31e199c7525))
* prepare Rust before parallel CI tasks ([c2107bb](https://github.com/IlyaGulya/wrenflow/commit/c2107bbdcc410081fe072e34407c8056256a8673))
* publish beta release with explicit repository context ([65f2227](https://github.com/IlyaGulya/wrenflow/commit/65f222758ae1324fac0744dd888b28bbf3efdd17))
* stabilize release performance gates ([05ed860](https://github.com/IlyaGulya/wrenflow/commit/05ed8609ce23d2a9c5b39e6917a13dbd1f0dbc8d))
* use one supply chain tool environment ([eacc739](https://github.com/IlyaGulya/wrenflow/commit/eacc7396f093c5594d701d782d68d8bca5581f28))


### Performance

* embed GPUI Metal shaders at build time ([42ece32](https://github.com/IlyaGulya/wrenflow/commit/42ece32dc9013b13d945b1cb8fd436626073dda7))
* keep menu bar idle work event-driven ([dec7c02](https://github.com/IlyaGulya/wrenflow/commit/dec7c0233d3aba746517199b92b9649342c250d4))
* make cold launch evidence deterministic ([f19c32c](https://github.com/IlyaGulya/wrenflow/commit/f19c32c55118f675e5915269198d0252f11e56b9))
* make launch readiness deterministic ([cdd4ab6](https://github.com/IlyaGulya/wrenflow/commit/cdd4ab66b7510943c3186893041faa4a3e566f8b))
* overlap permission discovery with cold startup ([1ee7508](https://github.com/IlyaGulya/wrenflow/commit/1ee7508d3444d47475fae5e1a833e1a62e8b875d))


### Improvements

* add auto-disposed wizard draft state ([8ad413d](https://github.com/IlyaGulya/wrenflow/commit/8ad413dc4b8b42a6e8ea45499faedde9e6faf0f1))
* add base dart snapshot notifier ([5930da9](https://github.com/IlyaGulya/wrenflow/commit/5930da9a7a1c677513a1e2f374faed3b23d80890))
* bootstrap shell bridges explicitly ([ef4493c](https://github.com/IlyaGulya/wrenflow/commit/ef4493c6355efb5dc66033b45a6931c60b2c41f2))
* centralize runtime config updates in rust ([53a993d](https://github.com/IlyaGulya/wrenflow/commit/53a993df2e8798c0d48c6f9b9a9855bbee1a8266))
* derive settings and wizard presentation ([a1ad428](https://github.com/IlyaGulya/wrenflow/commit/a1ad42851f8042ba4b8e6e433fba37a2d7dda489))
* derive settings tab presentation ([b618661](https://github.com/IlyaGulya/wrenflow/commit/b61866138ef20f7fb6d676fa864cd1fc450a18df))
* derive shell capabilities from adapters ([6fdd2fd](https://github.com/IlyaGulya/wrenflow/commit/6fdd2fdaeda977501b94e8b3865349cad8ecc872))
* derive shell pipeline presentation ([52610d8](https://github.com/IlyaGulya/wrenflow/commit/52610d86ea70664fadeea9c09c80c3f161978b7c))
* derive tray and wizard presentation state ([e9cadb0](https://github.com/IlyaGulya/wrenflow/commit/e9cadb0620b55ab9750d101ab4492ac072044ccc))
* extract shared snapshot bridge helpers ([6a1ad12](https://github.com/IlyaGulya/wrenflow/commit/6a1ad129b19c2fe630f091c3209b1c7f4ce7b8a8))
* fan out runtime config from rust settings runtime ([680929d](https://github.com/IlyaGulya/wrenflow/commit/680929d858edbf697a3254e3739348d41ad56a92))
* isolate rust platform backends ([e4660d7](https://github.com/IlyaGulya/wrenflow/commit/e4660d7e878965a48cea2d95019be4dc1af0a203))
* isolate shell platform adapters ([e8f14ee](https://github.com/IlyaGulya/wrenflow/commit/e8f14eedc6b94afef831daccdc293147ae18835b))
* isolate tray shell adapter ([fb873f1](https://github.com/IlyaGulya/wrenflow/commit/fb873f19ba7dcb4d4293b5d0c56c89ea64bcb7c5))
* isolate window shell adapter ([d17ccd6](https://github.com/IlyaGulya/wrenflow/commit/d17ccd691c4b6eb5f87a09eaa101bf452aa90f6f))
* keep tray window actions state-driven ([3096cc9](https://github.com/IlyaGulya/wrenflow/commit/3096cc9d91ad9296797240a7d0a10ae85a594aa7))
* move runtime state behind rust snapshots ([3b9d02a](https://github.com/IlyaGulya/wrenflow/commit/3b9d02a95d9681f40e074fa11232cb9cb917e940))
* move settings persistence into rust ([f0fc974](https://github.com/IlyaGulya/wrenflow/commit/f0fc9749935afc23b6dd5de80c483b418c45cfd3))
* remove hidden runtime defaults and shell fallbacks ([70da3ba](https://github.com/IlyaGulya/wrenflow/commit/70da3baecab70226a4c46f06d400b268e8d1c60a))
* remove legacy groq settings and infra ([5790f4f](https://github.com/IlyaGulya/wrenflow/commit/5790f4f857434ded1a5980efe8a390b334e971bf))
* separate main window shell presentation ([cba1ae0](https://github.com/IlyaGulya/wrenflow/commit/cba1ae032abcba877735cb387f619de298f6dff8))
* simplify selected model action flow ([78b179c](https://github.com/IlyaGulya/wrenflow/commit/78b179c79d0872a163ff4a26f11d2b9d52e9ced1))
* structure actor runtime bootstrap ([af31c00](https://github.com/IlyaGulya/wrenflow/commit/af31c00533bad7ec13bdd75b0d7b12f850c412c9))

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
