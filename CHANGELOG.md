# Changelog

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
