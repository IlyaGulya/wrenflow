# GPUI performance, energy and memory acceptance

Wrenflow's versioned production ceilings live in
[`support/performance/budgets-v1.json`](../support/performance/budgets-v1.json).
The machine contract is `gpui-performance-v1`. It applies only to the current
GPUI line and its default pinned Parakeet TDT
0.6B int8 model. There is no Flutter, legacy-data or pre-GPUI baseline.

The release gate is deliberately stricter than a developer benchmark. A valid
hybrid result binds the same source commit, complete signed app tree hash,
executable hash, CDHash and candidate ID on two hosts. `verify --profile
release` rejects dirty source, ad-hoc signatures, incomplete metrics, changed
evidence, candidate drift, or evidence recorded on the wrong host class.

## What is and is not minimum-machine evidence

The local development host used to build this harness is a physical 10-core M1
Max with 64 GiB on macOS 26.5.1. It is the valid Instruments and display/UI
half of the hybrid gate. Automated hotkey-handler-to-overlay and
release-handler-to-paste latency comes from the separately classified
signed-app `post_event_tap_synthetic` phase; it is not real event-tap,
microphone, external keyboard, TCC or human evidence. The host is not relabeled
as a base M1.

GitHub documents the standard `macos-14` arm64 runner as a three-CPU M1 VM with
7 GB RAM: less CPU and memory than the supported base-M1/8-GiB machine. It is
the accepted constrained half for deterministic non-interactive launch,
idle/resource, model, 50-row history and 20-fixture-cycle evidence. The
workflow in `.github/workflows/performance-preflight.yml` verifies the actual
`sysctl`, OS, architecture, Xcode and required xctrace templates on every run.
It is not physical hardware and cannot contribute microphone, TCC, overlay,
paste or human display evidence. GitHub also states that nested virtualization
is unavailable on its arm64 runners. See the
[GitHub-hosted runner specification](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
The [runner-images release feed](https://github.com/actions/runner-images/releases)
has announced macOS 14 image retirement by November 2, 2026; before that date
this gate needs a self-hosted equivalent or an
explicitly reviewed support/validation policy change. A newer, faster runner
label must not silently replace the constrained result.

Tart 2.32.1 is installed on the current M1 Max host and can create an isolated
macOS 14 guest. The official Tart configuration supports explicit CPU, memory
and display sizes and its runner exposes host audio unless `--no-audio` is
used. A disposable guest can therefore provide valuable clean-account/TCC and
8-GiB pressure evidence after microphone input is proved in that guest. It is
secondary evidence only: Virtualization.framework on an M1 Max is not a
physical base M1, and neither the virtual CPU nor energy counters establish the
support-floor budget. The documented starting point is `tart set <vm> --cpu 4
--memory 8192 --display 1440x900`; do not create or mutate a VM merely to make a
release result pass. See the [Tart VM configuration
documentation](https://tart.run/quick-start/#configuring-a-vm).

Tart evidence does not replace either required hybrid half. A physical base M1
remains valuable support-matrix coverage for `.9.9`, but its absence alone does
not keep `.9.5` open. The constrained workload uses a private performance
self-test compiled into the signed app and launched by
LaunchServices. It must require both the exact `--performance-self-test`
argument and the exact `WRENFLOW_PERFORMANCE_SELF_TEST=gpui-performance-v1`
environment value plus canonical fixture/disposable-root inputs, initialize
the normal `AppModel` and production runtime,
verify the version-controlled fixture SHA-256, reuse one warmed model for exactly
20 transcriptions, persist exactly 50 current-format History rows, emit only
closed privacy-safe markers, write a bounded machine-readable report and exit
on its own. Either gate alone, an output-path override or an unsafe/non-empty
root must fail closed, and ordinary launches must be unable to enter the path.

The immutable input manifest is
`support/performance/transcription-fixture-v1.json`: the 11-second, mono,
16-kHz PCM sample at `samples/jfk.wav` from whisper.cpp commit
`968eebe77225d25e57a3f981da7c696310f0e881`, SHA-256
`59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.
It is test input only and is not bundled as user data. Fetch it to an explicit
absolute non-symlink path with
`scripts/perf/download-transcription-fixture.sh`; the downloader refuses an
existing mismatch and publishes nothing until both size and digest match.

## Measurement conditions

Use one immutable Developer-ID-signed app for the whole run. Do not rebuild,
resign, install a different bundle at the same path, edit its resources, change
the model revision, or mix traces from another process. The harness resolves
the process by the exact executable path so a Flutter reference or another
bundle with a similar name cannot contaminate results.

Required conditions shared by both halves are:

- the exact same immutable arm64 Developer-ID-signed candidate and clean source
  commit;
- Xcode 16.2 selected and the required Instruments templates present;
- current pinned Parakeet model already verified, except during the dedicated
  download/load phases;
- default 60 Hz display, 100% app text scale, light appearance for the numeric
  baseline; adaptive variants are functional acceptance in `.9.10`;
- quiet foreground load, network at least 100 Mbps for the download budget,
  and no unrelated screen/audio recording;
- the runner half is exactly GitHub-hosted `macos-14`, M1, 7 GB; the physical
  half is the supported M1 Max/macOS 26 machine on AC power with Low Power Mode
  off and nominal thermal state;
- the immutable fixture-backed synthetic interaction source is used only by
  the two-gate signed-app mode and never attributed to a microphone.

`top` is kept alive for the complete phase: interval CPU, resident size,
thread count, absolute idle-wakeup deltas and the Activity Monitor energy proxy
come from one observer. Sample timestamps are observer-delivery times after
`top` finishes its global collection/render/flush pass, not kernel sample
timestamps. `lsof` samples numeric descriptors every five seconds and is also
forced once on every first accepted resource row after a direct completion.
Structured Wrenflow diagnostics contribute only closed event codes, timestamps,
session IDs and correlation IDs. No transcript, audio, device, target-app name,
window title, serial number or platform UUID enters an evidence JSON.

## Reproducible capture

Set explicit paths first. The evidence directory must be outside the app and
must not contain previous candidate output.

```bash
export WRENFLOW_PERF_APP="$PWD/build/gpui/Wrenflow.app"
export WRENFLOW_PERF_DIR="$PWD/build/performance/candidate-<commit>"
export WRENFLOW_PERF_INTERACTIVE="$WRENFLOW_PERF_DIR/physical-interactive.json"
export WRENFLOW_PERF_CONSTRAINED="$WRENFLOW_PERF_DIR/github-macos14-constrained.json"
mkdir -p "$WRENFLOW_PERF_DIR"

mise run performance-preflight -- \
  --app "$WRENFLOW_PERF_APP" \
  --output "$WRENFLOW_PERF_DIR/preflight.json" \
  --require-interactive
```

The preflight must pass before collecting release evidence. Launch the exact
bundle through LaunchServices, never its Mach-O:

```bash
mise exec -- open -n "$WRENFLOW_PERF_APP"
```

Launch readiness is route-aware. A same-session `startup` and
`menu_bar_ready` must be followed by exactly one terminal window-policy
marker after the initial non-Loading route is applied. The observer then
requires the exact LaunchServices bundle ID, bundle path and PID to report
`UIElement` for `window_policy_accessory_ready`, or `Foreground` for
`window_policy_foreground_ready`. A transient pre-marker `UIElement` state is
not evidence. The recorded latency ends at the later of the terminal marker
and its matching LaunchServices observation, so a fresh runner that truthfully
opens Onboarding or Permission Recovery remains valid Foreground launch
evidence rather than being mislabeled as menu-bar residency.

Transfer the byte-identical signed app and clean checkout to the constrained
runner without rebuilding. Its preflight must pass
`--expect-github-macos14`. Collect exactly twenty cold samples on twenty
distinct fresh GitHub-hosted macOS 14 runners. This cohort reports the
nearest-rank p95 (the nineteenth ordered sample); its raw maximum remains
informational and cannot replace or relax the p95 budget. The explicit
assertion appends one sample and is forbidden with multiple automatic
iterations. Preserve the result as a sealed, sanitized workflow artifact from
each fresh job.

```bash
mise exec -- python3 scripts/perf/gpui-performance.py launch \
  --app "$WRENFLOW_PERF_APP" --mode cold --iterations 1 --cold-confirmed \
  --fresh-runner-id "gh-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-cold-${WRENFLOW_COLD_SHARD}" \
  --output "$WRENFLOW_PERF_CONSTRAINED"
```

Every sample also retains a closed ordered diagnostic-stage map from runtime
bootstrap through AppModel, Swift shell, tray projection and truthful window
policy. The primary constrained job imports exactly twenty such shards through the
harness—not an ad-hoc JSON rewrite. `performance-merge-cold` rejects unsealed,
pathful, wrong-host, duplicate, mixed-candidate, mixed-source, multi-sample or
unexpected-metric shards and recomputes the twenty-sample p95:

```bash
mise run performance-merge-cold -- \
  --app "$WRENFLOW_PERF_APP" \
  --result "$WRENFLOW_PERF_CONSTRAINED" \
  --candidate-id "$WRENFLOW_PERF_CANDIDATE_ID" \
  $(for shard in $(seq 1 20); do printf '%s ' --shard "$WRENFLOW_PERF_DIR/cold-$shard.json"; done)
```

Then collect ten warm LaunchServices restarts. The harness sends the shell's
typed `SIGUSR1` quit request only after re-verifying the exact candidate
executable path and waits for full runtime/AppKit cleanup.

```bash
mise exec -- python3 scripts/perf/gpui-performance.py launch \
  --app "$WRENFLOW_PERF_APP" --mode warm --iterations 10 \
  --output "$WRENFLOW_PERF_CONSTRAINED"
```

The constrained 30-minute idle phase is collected by the gated self-test below,
not by leaving an ordinary fresh-account launch running with its required
Onboarding or Permission Recovery window visible. Standalone resource phases
remain useful only for additional physical-host attribution. The automated
60-second hold is owned by the signed synthetic interaction mode below; it
does not establish M06.

```bash
mise run performance-sample -- \
  --app "$WRENFLOW_PERF_APP" --phase idle_10m --duration 600 \
  --output "$WRENFLOW_PERF_CONSTRAINED"
```

The constrained signed-app self-test starts from a truly empty disposable root.
Its already exact argument/environment gates are the only authority to suppress
automatic Onboarding and Permission Recovery window presentation; the actual
route, permission state and configuration remain unchanged. The observer first
requires the same PID and bundle to reach terminal Accessory/`UIElement` state,
collects the fixed-count 30-minute idle phase while the runtime remains blocked
on its existing start signal, and then re-verifies the exact Accessory identity
and absence of a same-session `window_policy_apply_failed`. Only then does it
atomically create the start signal. The same process uses the normal production
downloader to fetch and hash-verify the pinned Parakeet revision once, measures
download and cold load/prewarm separately, then keeps one warmed engine for 20
immutable fixture transcriptions. The harness owns the LaunchServices
invocation, both policy observations, canonical report import and clean-exit
proof:

```bash
export WRENFLOW_PERF_FIXTURE="$WRENFLOW_PERF_DIR/jfk.wav"
export WRENFLOW_PERF_ROOT="$WRENFLOW_PERF_DIR/disposable-root"
scripts/perf/download-transcription-fixture.sh "$WRENFLOW_PERF_FIXTURE"
mkdir "$WRENFLOW_PERF_ROOT"

mise run performance-self-test -- \
  --app "$WRENFLOW_PERF_APP" \
  --fixture "$WRENFLOW_PERF_FIXTURE" \
  --data-root "$WRENFLOW_PERF_ROOT" \
  --output "$WRENFLOW_PERF_CONSTRAINED" \
  --idle-duration 1800
```

For a repeated functional smoke only, `--verified-model-cache <model-dir>` may
stage the five immutable assets after the app proves the root was empty and
before the start signal. The harness validates the production marker and every
source digest, deliberately omits the ready marker, and the production
downloader rehashes every destination byte before publishing its own marker.
Such a run is recorded as cache-staged, contributes no download metric and is
rejected by release provenance. The constrained release run must perform the
real network download.

Internally this passes only
`WRENFLOW_PERFORMANCE_SELF_TEST=gpui-performance-v1`,
`WRENFLOW_PERFORMANCE_FIXTURE`, `WRENFLOW_PERFORMANCE_DATA_ROOT` and the exact
argument through `open --env ... --args`; `WRENFLOW_PERFORMANCE_REPORT` is
explicitly rejected. The report is fixed at
`<root>/performance-self-test-v1.json`, and the observer start handshake is
the fsynced, zero-byte regular file `<root>/performance-start-v1`. The bounded
runtime wait for that signal exceeds the idle sampler's hard cadence deadline
but remains below the independent total workload timeout. As the
[Apple `top` source](https://github.com/apple-oss-distributions/top/blob/main/uinteger.c)
defines, absolute event mode appends `+` when an exact counter increased and
`-` when it decreased; the collector accepts the exact numeric `+` form,
rejects a decrease or malformed suffix, and computes wakeup rates from observed
monotonic deltas. Idle uses `fixed-count-monotonic-v1`: exactly 1,800 accepted
rows, at least 1,800 seconds of monotonic coverage, average cadence at most
1.25 seconds and no individual gap above two seconds. Active work uses
`event-bounded-monotonic-v1`: it retains the same row/counter/wall-clock
validity, 1.25-second aggregate cadence bound and 2,400-second outer deadline,
but terminates on the exact observer handshake instead of inventing a row count
or rejecting one isolated collection-heavy interval.
The report and closed diagnostics must prove
the fixture digest, exact cycle count, one-process warmed-engine reuse, 50-row
History snapshot and successful auto-exit. Its 20 completion boundaries drive
RSS/FD/thread end delta, RSS linear slope, and a fail-closed check that none of
those three resource families increases at every one of the final ten
boundaries. The existing regression test caps long cases at three and therefore
cannot be multiplied or relabeled as this evidence. Until the signed path
produces all 20 real completion markers, record no `cycles.completed.count`;
simply waiting, copying diagnostics or substituting a standalone test binary
does not pass. Each completion must map to a distinct first observer-delivered
resource row whose actual observed interval overlaps that transcription. All
20 mapped rows require fresh descriptor counts. The report's absolute
History-ready, activation, loading, model-ready and warmup timestamps must be
strictly ordered, agree with duration/diagnostic evidence within 100 ms, and
the raw rows must cover download, load and post-warm work. CPU and energy p95
use only those 20 mapped rows; post-warm RSS excludes download/load; global
peaks still use the complete active capture. After the
twentieth paired non-recording completion, the runtime remains alive behind a
second bounded handshake. The observer atomically publishes the exact
zero-byte, non-symlink `<root>/performance-observer-ack-v1` only after an
accepted resource row at or after that final completion. Pre-existing,
non-empty, symlinked, missing, 19-cycle or row-before-completion acknowledgments
fail closed; success/report finalization and auto-exit happen only after this
acknowledgment.

On a constrained failure the workflow may upload only the atomic mode-0600
`constrained-failure-summary.json` for seven days. It contains a fixed failure
code, phase/contract, bounded gap and reader-lag quantiles, row/stage counts,
and only the `top` return code plus a stderr category/hash. Raw stderr, samples,
diagnostics, app/data paths, transcripts and audio never enter this artifact;
its presence is diagnostic only and can never satisfy publish or verification.

On the physical host, run 20 real record-release-transcribe-paste cycles as
human acceptance only under `.9.9` M06. They are not required or inferred by
the `.9.5` automated latency evidence. No direct runtime command counts as a
user cycle. Follow the `.9.9` acceptance plan rather than adding those human
events to the automated `.9.5` result.

The self-test writes 50 acknowledged entries through the normal current-format
History service; it never imports or clears user/Flutter data. The harness then
opens that disposable SQLite database read-only and requires
`integrity_check=ok`, `user_version=1`,
the exact six-column `pipeline_history` schema and exactly 50 rows before it
records the resource envelope. On the
physical host, separately open, scroll and expand the same 50-entry shape for
display/frame evidence.

```bash
mise run performance-sample -- \
  --app "$WRENFLOW_PERF_APP" --phase history_50 --duration 120 --interval 1 \
  --output "$WRENFLOW_PERF_CONSTRAINED"
```

## Signed post-event-tap synthetic interaction markers

Use a second empty disposable root on the supported physical host and add
`--interaction`. The harness supplies the optional exact
`WRENFLOW_PERFORMANCE_INTERACTION=synthetic-in-process-v1` selector only beside
the existing exact argument/environment gates. The signed Wrenflow process
timestamps and invokes the same typed hotkey pressed/released callback used
immediately after the normal listen-only event tap. From that boundary onward
the normal `AppAction`/`RuntimeCommand`, model, History, overlay and paste paths
handle it. It never posts an OS keyboard event. Only the microphone source is
replaced by the already digest-verified fixture. The existing
`RuntimeEvent::PasteCompleted`, emitted only after the normal `paste_text`
function successfully dispatches Cmd+V, is the bounded automated endpoint.

```bash
export WRENFLOW_PERF_INTERACTION_ROOT="$WRENFLOW_PERF_DIR/interaction-root"
mkdir "$WRENFLOW_PERF_INTERACTION_ROOT"
mise run performance-self-test -- \
  --app "$WRENFLOW_PERF_APP" \
  --fixture "$WRENFLOW_PERF_FIXTURE" \
  --data-root "$WRENFLOW_PERF_INTERACTION_ROOT" \
  --output "$WRENFLOW_PERF_INTERACTIVE" \
  --interaction
```

The canonical private report proves exactly 20 typed callback pulses, one
60-second hold, handler-ingress-to-recording-overlay and
release-handler-ingress-to-production-paste-dispatch timing. The harness
imports only bounded timings and a hash, labels every derived metric
`post_event_tap_synthetic`, and records `tcc_or_microphone_evidence=false`.
Wrong, partial or ordinary launches cannot activate the source override. This
phase proves nothing about incoming CGEvent delivery, the event tap, a physical
key, actual target insertion, microphone or TCC. Human target-insertion proof
remains `.9.9` M07; keyboard/microphone/TCC proof remains `.9.9` M06.

## Instruments traces and attribution

Attach to an already LaunchServices-started exact candidate. The wrapper never
uses `xctrace --launch`, because launching the Mach-O through Instruments would
change Wrenflow's responsible process identity.

```bash
mise run performance-trace -- \
  "$WRENFLOW_PERF_APP" "Time Profiler" 600 \
  "$WRENFLOW_PERF_DIR/cycles-time-profiler.trace"
mise run performance-trace -- \
  "$WRENFLOW_PERF_APP" "Allocations" 600 \
  "$WRENFLOW_PERF_DIR/cycles-allocations.trace"
mise run performance-trace -- \
  "$WRENFLOW_PERF_APP" "System Trace" 600 \
  "$WRENFLOW_PERF_DIR/cycles-system.trace"
```

Capture the seven required contract templates named in the budget file across
the matching workload. `Power Profiler` is supporting attribution only: Xcode
16.2 on the pinned macOS 14 runner does not expose that template, so capture it
when the installed Xcode provides it, but never use its presence or absence to
satisfy a numeric energy budget. The energy gates remain the Activity Monitor
Energy Impact proxy sampled by the harness. Xcode's command-line reference
confirms that `xctrace` records and exports Instruments trace files; use
`mise exec -- xcrun xctrace export --input <trace> --toc` to record the table
schema before an XPath export.
Template schemas vary with Xcode, so derived numeric values are entered with
the trace hash instead of scraping an unstable guessed XPath:

```bash
mise exec -- python3 scripts/perf/gpui-performance.py record-metric \
  --result "$WRENFLOW_PERF_INTERACTIVE" \
  --metric ui.stalls.over_100ms.count --value 0 --sample-count 1 \
  --evidence "$WRENFLOW_PERF_DIR/cycles-time-profiler.trace"
```

Record every budget not emitted by the sampler the same way: model download
and cold load, Settings navigation, 50-row History open, frame pacing, and
render attribution. Definite leaks use the fail-closed live process guard after
the constrained idle phase, while the exact signed candidate is still running:

```bash
mise run performance-leaks -- \
  --app "$WRENFLOW_PERF_APP" --result "$WRENFLOW_PERF_INTERACTIVE" \
  --mode baseline
# Run exactly 20 externally driven, app-correlated cycles.
mise run performance-leaks -- \
  --app "$WRENFLOW_PERF_APP" --result "$WRENFLOW_PERF_INTERACTIVE" \
  --mode compare
```

When the exact target requires privileged attachment, add `--sudo`; this uses
only passwordless non-interactive `sudo -n` and otherwise has the identical
exact-PID parser and path-free evidence contract.

Both scans must use the same `MallocStackLogging=1` exact LaunchServices
process. The guard verifies its PID and executable before and after each
`/usr/bin/leaks --fullStacks --noContent`, parses exactly one process summary,
and persists only counts plus hashes of the private raw output and canonical
path-free summaries. It requires exactly 20 closed app diagnostic correlations
between scans and budgets only positive definite-leak growth, never the total.
The evidence-backed local startup baseline is 2 CFString objects / 112 bytes in
`AudioCapture::list_input_devices -> cpal::Device::name -> CoreAudio`; it stays
owned by non-blocking `wrenflow-bda`. Raw stacks are never uploaded. The
RSS/fd/thread growth guards complement this scan.

Create that retained stack-logged process without contaminating the ordinary
idle/resource result:

```bash
mise exec -- python3 scripts/perf/gpui-performance.py launch \
  --app "$WRENFLOW_PERF_APP" --mode warm --iterations 1 --leave-running \
  --malloc-stack-logging --output "$WRENFLOW_PERF_INTERACTIVE"
```

Each trace review must assign observed stacks to one of these owners in its
notes:

- GPUI screen/render code: navigation, layout, main-thread and full-tree work;
- Swift bridge: AppKit/SwiftUI panel creation, status item, event tap and paste;
- audio: input callback, buffering and Opus work;
- ONNX: model load, allocator pools and inference threads;
- runtime IO: SQLite, diagnostics, model verification and file descriptors.

Reject a trace if an audio tick triggers a full presentation/tree rebuild, a
main-thread stall exceeds 100 ms, or a variance lacks an owner and rationale.
The `Animation Hitches` track is supporting evidence; Time Profiler/System
Trace remain authoritative if the installed Xcode cannot expose a macOS hitch
table.

## Seal and verify

After every metric and trace is recorded, remove local paths and seal both JSON
documents with the same candidate ID. Any later edit changes the canonical
evidence hash and fails release verification; the verifier also rejects
different source/app hashes or evidence that was not explicitly sanitized.

```bash
mise exec -- python3 scripts/perf/gpui-performance.py sanitize \
  --result "$WRENFLOW_PERF_CONSTRAINED"
mise exec -- python3 scripts/perf/gpui-performance.py sanitize \
  --result "$WRENFLOW_PERF_INTERACTIVE"
mise exec -- python3 scripts/perf/gpui-performance.py seal \
  --result "$WRENFLOW_PERF_CONSTRAINED" \
  --candidate-id '<commit>-<dmg-sha256>'
mise exec -- python3 scripts/perf/gpui-performance.py seal \
  --result "$WRENFLOW_PERF_INTERACTIVE" \
  --candidate-id '<commit>-<dmg-sha256>'

mise run performance-verify -- \
  --profile release \
  --result "$WRENFLOW_PERF_CONSTRAINED" \
  --companion-result "$WRENFLOW_PERF_INTERACTIVE" \
  --report "$WRENFLOW_PERF_DIR/verification.json"
```

`performance-verify` requires every v1 numeric metric on the host class named
by `evidence_policy` and evaluates every matching measurement, so a faster host
cannot hide a constrained failure. A GitHub probe without the full workload,
Tart result, incomplete physical phase, unsigned app, dirty commit or unsealed
JSON may be attached for diagnosis but cannot be reported as a pass. Final
immutable-candidate M21 acceptance remains owned by `.9.11`.
