# Model Subsystem Design

Date: 2026-05-14

Status: historical design record. Flutter/Rinf paths describe the pre-GPUI
baseline; the shipping implementation now lives in `core/wrenflow-runtime` and
`native/wrenflow-gpui`.

## Goal

Redesign Wrenflow's local transcription model subsystem so that:

- users can choose a model in both Settings and the onboarding wizard
- download, install, load, and ready states are explicit and understandable
- the selected model runs efficiently on today's shipping platform and on the future cross-platform product line
- Whisper is supported as a first-class optional family using the best current variant for dictation
- old cloud-era Groq config is fully separated from local model selection

## Wrenflow Constraints

These recommendations are tailored to the current codebase, not to a generic speech app.

### Product constraints

- Wrenflow is a menu bar dictation app, not a batch transcript editor
- interaction is hold-to-record, release-to-transcribe, paste result
- perceived latency after key release matters more than long-form throughput
- startup regressions are unacceptable because the app lives in the menu bar and should feel invisible

### Platform constraints

- current shipping codepath is macOS only
- README currently positions the app around Apple Silicon + macOS 14+
- release builds today are signed macOS app bundles
- this is current state, not the target product boundary
- the new subsystem must not hard-code macOS-specific assumptions into model identity, settings, or catalog layout

### Architecture constraints

- Flutter UI + Riverpod state
- Rust core with Rinf signals
- single `native/hub` actor system
- current local ASR path is Parakeet via `parakeet-rs` + ONNX Runtime dynamic library
- current model lifecycle is driven by:
  - [lib/providers/app_lifecycle_provider.dart](/Users/ilyagulya/Projects/My/wrenflow/lib/providers/app_lifecycle_provider.dart)
  - [native/hub/src/actors/model_actor.rs](/Users/ilyagulya/Projects/My/wrenflow/native/hub/src/actors/model_actor.rs)
  - [native/hub/src/signals/mod.rs](/Users/ilyagulya/Projects/My/wrenflow/native/hub/src/signals/mod.rs)

### UX constraints already present in the app

- Settings and onboarding are the only valid places for model selection
- the app already shows model readiness globally in onboarding
- the app already has a concept of background initialization and prewarm
- `runApp` must stay off the heavy path

## Current State

Today the model subsystem is really a single hard-coded Parakeet boot path.

### Rust

- `default_parakeet_model()` is the only model descriptor:
  - [core/wrenflow-domain/src/model_management.rs](/Users/ilyagulya/Projects/My/wrenflow/core/wrenflow-domain/src/model_management.rs)
- `model_actor` always downloads or loads that one model:
  - [native/hub/src/actors/model_actor.rs](/Users/ilyagulya/Projects/My/wrenflow/native/hub/src/actors/model_actor.rs)
- the loaded runtime is stored in one `SharedTranscriptionEngine`
- `ModelStateChanged` is global and has no `modelId`

### Flutter

- [lib/widgets/model_download_widget.dart](/Users/ilyagulya/Projects/My/wrenflow/lib/widgets/model_download_widget.dart) only knows one model and one button
- onboarding only reflects generic readiness state, not model choice:
  - [lib/screens/setup_wizard_screen.dart](/Users/ilyagulya/Projects/My/wrenflow/lib/screens/setup_wizard_screen.dart)
- Settings currently have no local model picker

### Persistence

- `AppSettings` still carries old cloud-era fields:
  - `apiKey`
  - `apiBaseUrl`
  - `transcriptionProvider`
  - `transcriptionModel`
- these are stored in [lib/providers/settings_provider.dart](/Users/ilyagulya/Projects/My/wrenflow/lib/providers/settings_provider.dart)

This is dangerous because `transcriptionModel = whisper-large-v3-turbo` currently looks like it might mean a local model choice, but in practice it is leftover configuration debt.

## Main Problems

### 1. No real model identity

The system cannot currently represent:

- multiple model families
- different runtimes/backends
- installed vs selected vs active model
- model versioning
- model capabilities

### 2. State model is too coarse

The current `ModelState` cannot represent:

- multiple installed models
- per-model download progress
- checksum verification
- downloaded-but-not-selected
- selected-but-not-active
- switching active model
- active prewarm per model

### 3. UX is under-specified

Users need to decide:

- speed vs accuracy
- multilingual vs dictation-first
- download now vs later
- what is currently active
- what switching will do

Current UI only says "download model".

### 4. Local and retired cloud settings were mixed

This is architectural debt and should be treated as part of the redesign, not cleanup for later.

## Product Direction

Wrenflow should expose local transcription as:

- a catalog of installable local models
- one selected model
- one active loaded runtime
- many optionally installed models

User mental model:

- choose the default transcription model
- see whether it is installed
- download another one later if needed
- switch without losing trust in what the app is doing

## Recommended Model Strategy

### Default model family

Keep Parakeet as the default path for dictation.

Why this fits Wrenflow:

- the app is optimized around short press-to-talk dictation bursts
- release-to-text latency matters more than translation support
- the existing runtime and packaging already support Parakeet
- it is the lowest-risk path to shipping model selection without rewriting the entire ASR stack first

Recommended default:

- `parakeet-tdt-0.6b-v3-onnx`

### Whisper support

Add Whisper as a first-class optional family.

Recommended first Whisper option:

- `openai/whisper-large-v3-turbo`

Why:

- OpenAI's current Whisper repo describes `turbo` as an optimized `large-v3` with faster transcription and only minor quality loss
- OpenAI's current examples default to `turbo` for transcription
- for local dictation, this is the best current Whisper tradeoff

Recommended second Whisper option:

- `openai/whisper-large-v3`

Why:

- it gives an explicit "max accuracy" option
- it prevents `turbo` from becoming the only interpretation of Whisper support

### Wrenflow-facing model lineup

For the first iteration, keep the product simple:

- `Parakeet Realtime`
- `Whisper Turbo`
- `Whisper Large`

Do not add five or six model variants immediately. The product is still a dictation app, not a model zoo.

## Recommended Runtime Strategy

### Backend split

Introduce explicit runtime backends in the domain:

- `parakeet_onnx`
- `whisper_cpp`

Planned but not required for phase 1:

- `parakeet_coreml`
- `whisper_coreml`

These backend ids should not become the primary user-facing setting. They are runtime implementation detail.

### Why `whisper.cpp` is the right first Whisper backend here

For Wrenflow specifically, prefer a Rust-native embedding around `whisper.cpp`.

Why this fits the existing project better than a Python-side runtime:

- Wrenflow already centers its non-UI logic in Rust
- shipping a Python runtime inside a signed menu bar app is heavier operationally and harder to reason about
- `whisper.cpp` supports Apple Silicon-friendly quantized model assets
- `whisper.cpp` supports Metal and optional Core ML encoder acceleration on macOS
- there are Rust bindings available, which fit the current actor architecture much better than supervising a Python service

### Runtime resolution

Treat model family and runtime backend as separate concerns.

Suggested direction:

```rust
pub struct LocalModelSelection {
    pub model_id: String,
    pub execution_profile: LocalExecutionProfile,
}

pub struct ResolvedRuntimePlan {
    pub model_id: String,
    pub backend: LocalModelBackend,
    pub device: RuntimeDevice,
    pub asset_variant: String,
}
```

Resolution rules:

- the user picks a model family
- the app resolves the best backend for the current platform
- the catalog exposes which asset variants exist per platform
- unsupported combinations fail during resolution, not halfway through model load

### Apple Silicon now

For Whisper on the current shipping hardware:

- use quantized local assets
- use Metal by default
- treat Core ML encoder acceleration as an optimization layer, not as the only supported mode

For Parakeet on the current shipping hardware:

- keep the current ONNX Runtime path as the baseline
- later add a dedicated optimized backend if benchmarks justify it

### Cross-platform target

For the long-term product:

- keep `LocalModelDescriptor` platform-neutral
- attach backend support as a capability matrix, not as separate user-facing models
- allow one model family to map to different runtime plans on macOS, Windows, Linux, iOS, and Android
- benchmark each platform independently before promoting a backend to default

## Model Catalog Design

Replace the hard-coded single-model logic with a catalog.

### Rust domain types

Suggested direction:

```rust
pub enum LocalModelBackend {
    ParakeetOnnx,
    WhisperCpp,
}

pub struct LocalModelDescriptor {
    pub id: String,
    pub family: String,
    pub display_name: String,
    pub summary: String,
    pub language_scope: ModelLanguageScope,
    pub recommended_for_dictation: bool,
    pub recommended_for_accuracy: bool,
    pub download_size_bytes: u64,
    pub install_size_bytes: u64,
    pub expected_memory_bytes: u64,
    pub runtime_plans: Vec<RuntimePlanDescriptor>,
    pub assets: Vec<ModelAssetFile>,
}

pub struct RuntimePlanDescriptor {
    pub backend: LocalModelBackend,
    pub platforms: Vec<TargetPlatform>,
    pub asset_variant: String,
}

pub struct ModelAssetFile {
    pub relative_path: String,
    pub url: String,
    pub sha256: String,
    pub size_bytes: u64,
}
```

Suggested `language_scope` values:

- `EnglishOnly`
- `Multilingual { languages: Vec<String> }`

### Important rule

The catalog must become authoritative for:

- UI labels
- download size
- file list
- checksums
- supported runtime plans

The actor should not infer model behavior from UI strings or hard-coded `if model == ...` checks in multiple places.

## Persistent Settings Design

Do not reuse the old `transcriptionModel`.

Add explicit local-model fields:

```dart
selectedLocalModelId
preferredLocalExecutionProfile
```

Use these meanings:

- `selectedLocalModelId`: the user-facing model choice
- `preferredLocalExecutionProfile`: optional hint such as `balanced`, `fastest`, or `highest_accuracy`

Do not persist a raw backend choice such as `whisper_cpp` as the main user selection. Backend resolution should stay platform-specific.

### Historical pre-clean-break settings proposal

The following was a Flutter-era proposal, not a current GPUI data contract. It
would have split configuration into:

- user preferences
- local model choice
- retired cloud-provider fields

The clean-break GPUI implementation instead starts from the current-format
`gpui-v1` model settings and never imports those retired fields. Historical
intent was:

- keep `apiKey`, `apiBaseUrl`, `transcriptionProvider`, and old `transcriptionModel` outside local model selection
- stop surfacing them in any local transcription UX
- never use them as the source of truth for the selected local model

### Current clean-break rule

On first GPUI launch:

- if no current-format local model setting exists, default to `parakeet-tdt-0.6b-v3-onnx`
- do not read, preserve, or rewrite pre-GPUI model settings
- never use retired model names to drive runtime selection

## Actor and Signal Architecture

This is where the redesign should align tightly with Wrenflow's current shape.

### Replace single-purpose `model_actor` with a model manager

Responsibilities:

- publish catalog
- resolve installed models
- download model assets
- verify checksums
- load backend runtime
- prewarm runtime
- switch active runtime
- unload previous runtime

### Preserve current actor model

Do not add a sidecar daemon or second process.

The right direction for Wrenflow is still:

- Flutter UI
- Rinf signals
- Rust actor owns runtime state

### Signal changes

Current signals are too global.

Recommended additions:

- `LocalModelsListed`
- `LocalModelSelectionChanged`
- `LocalModelStateChanged { model_id, state }`
- `SelectLocalModel { model_id }`
- `DownloadLocalModel { model_id }`
- `RemoveLocalModel { model_id }`
- `ResolveLocalModelRuntime { model_id }`

Recommended replacement for the current global-only flow:

- keep a global `active_model_id`
- but make readiness and download state per-model

### Runtime invariant

At any given time:

- one model is selected
- zero or one model is active in memory
- many models can be installed on disk

This keeps the complexity bounded and matches the app's dictation workflow.

### Startup policy change

The current [lib/providers/app_lifecycle_provider.dart](/Users/ilyagulya/Projects/My/wrenflow/lib/providers/app_lifecycle_provider.dart) sends `InitializeLocalModel()` immediately on startup.

That should change to:

- enumerate installed models in background
- resolve the selected model
- load only the selected runtime plan
- publish install-needed state when no local model is installed yet

## Download Pipeline

### Requirements

- resumable downloads if practical
- temp-file writes followed by atomic rename
- checksum verification
- per-file progress
- aggregate progress
- cancellation
- retry behavior

### Directory layout

Move away from the current fixed Parakeet-only directory.

Suggested structure:

```text
<app-data>/models/
  catalog.json
  parakeet-tdt-0.6b-v3-onnx/
    manifest.json
    files...
  whisper-large-v3-turbo/
    manifest.json
    model.bin
    auxiliary/
```

This should still be resolved through the same `dirs`-based path logic already used elsewhere in the project, with each platform mapping to its own writable app data root.

### Installed manifest

Each installed model should write a manifest with:

- id
- backend
- asset versions
- verified timestamp
- whether prewarm cache has been completed at least once

That keeps startup cheap and avoids blind revalidation.

## Loading and Performance

### 1. Keep startup light

This is critical for Wrenflow because startup regressions already hurt the menu bar UX.

Rules:

- never block `runApp` on model enumeration, verification, or load
- never auto-load a non-selected model
- keep discovery async

### 2. Preserve prewarm as a first-class concept

The existing Parakeet path already prewarms after load.

Generalize this so every backend implements:

- `load`
- `prewarm`
- `transcribe`
- `unload`

### 3. Add a lightweight silence gate

For phase 1:

- simple energy-based VAD before expensive inference

Why this fits Wrenflow:

- it is easy to implement inside the current Rust audio/transcription pipeline
- it reduces wasted inference on accidental taps and near-silent segments

### 4. Model switching policy

When the user changes the selected model:

- if installed and warm, switch immediately
- if installed but not loaded, show `Loading`
- if not installed, offer `Download` and keep the current model active until the new one is ready

This prevents "I clicked a model and now dictation is broken" moments.

### 5. Backend-specific performance policy

For phase 1:

- optimize Parakeet in the current ONNX path
- add Whisper through a native backend that does not require Python
- benchmark actual release builds on Apple Silicon before adding more variants

Do not overfit the subsystem around streaming partial-text speculation yet. Wrenflow currently transcribes on release, not continuously while speaking.

For the broader platform roadmap:

- keep the runtime trait identical across platforms
- allow platform-specific backend resolution under the same model id
- benchmark each platform before changing the default runtime plan

## Settings UX

Add a `Transcription model` card to Settings > General.

### Row content

Each model row should show:

- display name
- one short subtitle
- one or two badges only
- installed/not installed
- action

Recommended rows:

- `Parakeet Realtime`
  - subtitle: `Fastest local dictation`
  - badges: `Default`, `Installed`

- `Whisper Turbo`
  - subtitle: `Best Whisper speed/accuracy tradeoff`
  - badge: `Multilingual`

- `Whisper Large`
  - subtitle: `Highest Whisper accuracy`
  - badge: `Slower`

### Detail area

When a row is selected, show:

- installed size
- status
- active/inactive
- whether switching requires load
- remove action for non-default installed models

## Onboarding UX

Model choice should be part of onboarding, not hidden until after setup.

### Recommended wizard structure

1. microphone
2. accessibility
3. hotkey
4. model choice
5. model download / ready
6. vocabulary
7. complete

If needed, steps 4 and 5 can be merged.

### Onboarding behavior

Default selected model:

- `Parakeet Realtime`

Alternative shown immediately:

- `Whisper Turbo`

The wizard should explain:

- why one model is recommended
- approximate size
- that another model can be downloaded later in Settings

## `ModelDownloadWidget` Redesign

The current widget is single-model and Parakeet-branded.

It should become catalog-aware and accept:

- selected model descriptor
- selected model install state
- selected model active state

It should show:

- model name
- download size
- phase
- total progress
- current file if downloading
- `Download`, `Cancel`, `Retry`, `Use`

It should stop hard-coding text like:

- `Download Parakeet model`
- `Local Transcription Model`

## Recommended Scope

### Phase 1

- catalog
- new local model settings
- per-model install state
- settings picker
- onboarding picker
- Parakeet default
- Whisper Turbo support
- checksum verification
- backend-agnostic prewarm
- async switch/load
- remove Groq wording from all local-model UI and signal naming

### Phase 2

- keep retired Groq-backed keys outside the GPUI current-format namespace
- uninstall support
- performance telemetry
- energy VAD gate
- backend benchmarks in release builds

### Phase 3

- optional Core ML optimized backend variants
- smarter load heuristics
- optional partial-result UX if the product ever moves toward streaming dictation

## Concrete Implementation Plan

### Phase A: Domain and persistence

- add model catalog structs in `wrenflow-domain`
- add local model setting keys in `settings_provider`
- keep retired model fields outside local runtime selection
- split user model selection from backend resolution
- default a new current-format selection to `parakeet-tdt-0.6b-v3-onnx`

### Phase B: Signals and actor

- replace hard-coded `default_parakeet_model()` boot flow with selected-model flow
- add model catalog and selection signals
- make model state per-model
- keep a single active runtime handle

### Phase C: UI

- replace the single-model download widget behavior with catalog-based behavior
- add model picker to Settings > General
- add model choice to onboarding
- make onboarding's global indicator reference the selected model

### Phase D: Whisper backend

- add Rust wrapper around the chosen Whisper runtime
- add `whisper-large-v3-turbo` descriptor
- add `whisper-large-v3` descriptor
- implement load, prewarm, transcribe, unload
- make backend resolution pluggable so non-macOS ports do not require later settings-schema churn

### Phase E: Performance polish

- background discovery only
- load selected model lazily
- keep prewarm explicit
- add silence gate
- measure real-world latency in release builds on Apple Silicon

## Historical provider cleanup boundary

This is mandatory for the redesign.

Actions:

- remove Groq wording from local model UX
- keep old cloud fields outside GPUI current-format code
- do not mix remote provider naming with local model identity
- never import retired cloud keys into the local model path

Recommended rule:

- `AppSettings` holds user preferences
- `LocalModelCatalog` holds installable local assets
- `ResolvedRuntimePlan` decides how a selected model runs on the current platform
- `RuntimeModelState` holds what is active now

These concerns must stay separate.

## Recommendation Summary

If only one version of this redesign ships, it should be:

- Parakeet remains the default dictation model
- Whisper Turbo is the main optional Whisper path
- local model selection is explicit in Settings and onboarding
- downloads and readiness are per-model, not global
- the runtime stays Rust-native and Rinf-driven
- model choice stays platform-neutral while backend resolution is platform-specific
- old Groq config is fully separated from local model identity

## Sources

Primary sources used for Whisper/runtime direction:

- OpenAI Whisper repository
  - https://github.com/openai/whisper
- OpenAI `whisper-large-v3-turbo` model card
  - https://huggingface.co/openai/whisper-large-v3-turbo
- `whisper.cpp` README
  - https://github.com/ggml-org/whisper.cpp
