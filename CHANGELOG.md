# Changelog

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
