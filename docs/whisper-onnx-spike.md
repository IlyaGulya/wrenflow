# Whisper ONNX Spike

This spike investigates whether Wrenflow can rescue the current macOS Whisper path by:

1. improving the existing ONNX runtime loop,
2. enabling ONNX Runtime CoreML Execution Provider,
3. benchmarking alternative ONNX exports,
4. exporting our own `openai/whisper-large-v3-turbo` bundle with the official Optimum exporter.

## Current Findings

### Current frontier: bucketed encoder exports

The strongest current speed lever is not another runtime flag or a broader quantization pass. It is shrinking the fixed Whisper encoder time axis away from `3000` frames.

Hardware baseline for the numbers below:

- Apple M1 Max
- 8 performance cores + 2 efficiency cores
- 64 GB RAM
- cache line size: 128 bytes

We now have a reproducible bucketizer:

```bash
python3 scripts/bucketize-whisper-onnx.py \
  "$HOME/Library/Application Support/Wrenflow/model-backups/whisper-large-v3-turbo-20260516-132808" \
  /tmp/wrenflow-whisper-export/current-bucket-1664 \
  1664
```

Key bucket results against the shipping baseline on the same release harness:

- current shipping bundle:
  - transcribe: ~`2.35s`
  - quality avg: ~`0.422`
- `bucket1536`:
  - transcribe: ~`1.25-1.44s`
  - quality avg: ~`0.398`
- `bucket1600`:
  - transcribe: ~`1.17s`
  - quality avg: ~`0.386`
- `bucket1664`:
  - transcribe: ~`1.51s`
  - quality avg: ~`0.403`
- `bucket1792`:
  - transcribe: ~`1.63s`
  - quality avg: ~`0.378`
- `bucket2048`:
  - slower than baseline and not attractive

Practical conclusion:

- bucketing works; the fixed `3000` encoder window was the main bottleneck,
- `1600` is the fastest plain bucket on this M1 Max, but quality drops a bit more,
- `1664` is currently the best plain bucket compromise, and is the live installed Whisper bundle on the M1 Max dev machine,
- `1536` is faster but drifts a bit more,
- pushing bucket size back up does not automatically recover quality.

Apple-specific note:

- the tempting “pick only nice 128-frame / 64-step aligned buckets” heuristic is not enough by itself,
- `1600` (`encoder_steps=800`) slightly beat `1664` (`encoder_steps=832`) on latency despite looking less “clean” from a simple alignment perspective,
- so bucket policy should stay empirical and product-metric-driven on Apple Silicon, not based on cache/tile folklore alone.

### Bucket + selective quantization

We also tested combining the strongest bucket path with the best selective quantization path:

- `hybrid-r8` on full `3000` frames:
  - transcribe: ~`2.19s`
  - quality avg: ~`0.417`
- `bucket1536 + hybrid-r8`:
  - transcribe: ~`1.72s` average, with steady-state runs around `1.32-1.35s`
  - quality avg: ~`0.320`

Conclusion:

- selective quantization and bucketing do not combine cleanly yet,
- the combined candidate is fast but quality regresses too hard,
- for now, the useful frontier is:
  - `hybrid-r8` if we optimize for safer quality,
  - `bucket1664` if we optimize for latency.

### Initial prompt / vocabulary bias

We also tried recovering bucket quality by injecting a short Whisper initial prompt from custom vocabulary / hotwords.

Result on the current runner:

- this was highly unstable,
- even a short prompt like `Whisper Turbo, hostname, progress bar, UI` caused near-empty or badly derailed outputs,
- the failure affected both the shipping baseline and bucketed variants.

Conclusion:

- initial prompt bias is currently **experimental only**,
- it is gated behind `WRENFLOW_WHISPER_ENABLE_INITIAL_PROMPT=1`,
- it should not be enabled by default in product until we understand the decoder contract better.

## App-Level QA Pass For `bucket1664`

Use the currently installed live bundle on the M1 Max dev machine and validate through the actual app flow, not just harness tests.

Quick metrics helper:

```bash
mise run summarize-whisper-history
```

Recommended manual scenarios:

1. Short Russian phrase, 1-2s.
   Expect:
   - successful transcript,
   - `transcription.durationMs` roughly in the low-`1.xs` to low-`3.xs` range,
   - no empty transcript,
   - no model/runtime toast.

2. Technical mixed phrase, 2-4s.
   Example terms:
   - `Whisper Turbo`
   - `hostname`
   - `progress bar`
   - `UI`
   Expect:
   - possible minor spelling drift,
   - but no catastrophic derailment,
   - no repeated collapse into English gibberish.

3. Longer phrase, 5-10s.
   Expect:
   - stable decode,
   - no timeout / loading regressions,
   - still meaningfully faster than the old `3000`-frame baseline.

4. Repeated hotkey runs.
   Expect:
   - warm-path timings remain stable,
   - no startup recompile behavior,
   - no growing latency across consecutive runs.

5. Cold launch then first Whisper run.
   Expect:
   - first prewarm is slower,
   - but later runs should converge toward the warm-path numbers.

Pass criteria for keeping `bucket1664` live:

- no product-breaking regressions in real dictation,
- recent Whisper history stays dominated by successful outcomes,
- short-to-medium dictation remains clearly faster than the previous full-window path,
- brand/technical word drift is annoying at worst, not catastrophic.

### Current shipping bundle

- Source: `onnx-community/whisper-large-v3-turbo-ONNX`
- Runtime: custom Rust ONNX loop in `core/wrenflow-core/src/transcription_whisper.rs`

### Graph-level comparison: why the current bundle is faster than our own export

Both the shipping community bundle and the official Optimum export use the same high-level Whisper encoder contract:

- `input_features`: `batch x 128 x 3000`
- encoder output: `batch x 1500 x 1280`

That means the fixed 3000-frame encoder window remains the dominant cost in both cases. The difference is in **how the graph is represented**:

- shipping community encoder:
  - file size: ~615 MB
  - ONNX opset: 14
  - nodes: 2275
  - key ops: `MatMulInteger`, `DynamicQuantizeLinear`
  - initializer mix: `FLOAT + INT8 + INT64`
- official Optimum encoder:
  - file size: ~504 KB + ~2.4 GB external data
  - ONNX opset: 14
  - nodes: 2943
  - key ops: plain `MatMul`
  - initializer mix: `FLOAT` only

In practice, the current bundle is already heavily quantized, while the official export is a much larger float graph. That directly explains why the official export loads slower and why its encoder pass is even worse in our runtime.

### Stage timings on a real saved recording

CPU-oriented ORT path:

- feature extraction: ~105ms
- encoder: ~4.44s
- language detection: ~63ms
- prompt decode: ~57ms
- decode loop: ~372ms
- total: ~5.04s

Conclusion: the main bottleneck is the encoder, not the decoder loop.

### CoreML EP result

Enabling ORT `CoreMLExecutionProvider` for the same graph made the path dramatically worse:

- encoder: ~17.85s
- total: ~22.59s

Conclusion: ORT + CoreML EP is not a viable acceleration path for this graph today.

Source-level note from ONNX Runtime:

- `vendor/onnxruntime-src/onnxruntime/core/providers/coreml/coreml_execution_provider.cc`
- CoreML EP explicitly partitions the graph into supported subgraphs via `GetSupportedNodes(...)`
- ORT logs a warning when it ends up with multiple CoreML partitions because that may hurt performance

So “ONNX supports Apple” is true, but for this graph the important question is whether CoreML EP can take a large coherent partition. Our benchmark says the answer is effectively “no” for this Whisper path.

### Alternative export: `lite-whisper`

- Candidate: `onnx-community/lite-whisper-large-v3-turbo-ONNX`
- Result: not drop-in compatible with the current runner
- Symptoms:
  - different architecture (`LiteWhisperForConditionalGeneration`)
  - different config contract
  - missing expected generation fields such as `suppress_tokens`

Conclusion: supporting `lite-whisper` would require a different runner, not just a model swap.

Graph/runtime reason:

- `lite-whisper` is not a vanilla Whisper drop-in
- it uses `LiteWhisperForConditionalGeneration`
- our runner expects the standard Whisper generation contract and token metadata
- `lite-whisper` therefore belongs in a separate backend or compatibility layer, not in the current runner

### Own export: official Optimum pipeline

Command:

```bash
scripts/export-whisper-onnx.sh openai/whisper-large-v3-turbo
```

This successfully exports a `with-past` bundle with:

- `encoder_model.onnx`
- `decoder_model.onnx`
- `decoder_with_past_model.onnx`
- standard Whisper config/tokenizer files

Benchmark result against the same saved recording:

- load: ~9.31s
- prewarm: ~6.66s
- transcribe: ~7.88s

Transcript quality was acceptable, but runtime was worse than the current community bundle.

Conclusion: a clean official export alone does not solve the latency problem.

### Own export + dynamic INT8 quantization

Command:

```bash
scripts/quantize-whisper-onnx.sh \
  /tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past \
  /tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-int8
```

Benchmark result against the same saved recording:

- load: ~2.27s
- prewarm: ~3.93s
- transcribe: ~3.81s

For comparison, the current shipping bundle on the same harness run measured:

- load: ~1.71s
- prewarm: ~2.74s
- transcribe: ~4.52s

This is the first ONNX experiment that materially narrows the gap:

- it does **not** solve the encoder-heavy fixed-window contract,
- but it does show that export representation and quantization matter a lot,
- and that a custom quantized export can outperform the current shipping bundle on raw transcribe latency in our debug harness.

Release-mode benchmark on the same test later showed a more conservative result:

- current shipping bundle:
  - load: ~1.54s
  - prewarm: ~3.90s
  - transcribe: ~4.49s
- custom official export + dynamic INT8:
  - load: ~1.34s
  - prewarm: ~4.37s
  - transcribe: ~5.17s

Conclusion: ONNX is not “dead”, but the naive `official export + dynamic INT8` path is **not yet a product upgrade** over the shipping bundle. It improves load time, but does not beat the current bundle on release-mode transcribe latency.

### Repeated warm release benchmark

To remove cold-path noise, the selected variants were benchmarked 3 times each on the same saved recording in release mode:

- current shipping bundle average:
  - load: ~1.264s
  - prewarm: ~2.528s
  - transcribe: ~2.673s
- custom official export + dynamic INT8 average:
  - load: ~0.961s
  - prewarm: ~2.889s
  - transcribe: ~3.155s
- custom official export + ORT offline optimize + dynamic INT8 average:
  - load: ~0.894s
  - prewarm: ~2.671s
  - transcribe: ~3.007s

Practical conclusion:

- the custom export variants are better at load time,
- they are competitive on prewarm,
- but the current shipping community bundle is still best on actual warm transcription latency.

So we still do **not** have enough evidence to replace the shipping bundle in product.

### Current runtime wins we actually kept

We did find one meaningful win inside the existing ONNX path:

- cache the Whisper feature extractor internals (`hann window`, `mel filterbank`, `FFT plan`, reusable FFT buffers)

Before that change, feature extraction alone was around `~105ms` on the same saved recording. After caching:

- feature extraction: ~`1.5ms`
- encoder: ~`2.3s`
- total transcribe: ~`2.6s`

This means preprocessing is no longer the bottleneck. The ONNX path is now dominated even more clearly by encoder inference itself.

### ORT runtime knobs: what helped and what did not

Repeated warm release benchmark on the current shipping bundle after the preprocessing cache:

- baseline:
  - load: ~`1.298s`
  - prewarm: ~`2.402s`
  - transcribe: ~`2.636s`
- `WRENFLOW_WHISPER_DISABLE_MEMORY_PATTERN=1`:
  - transcribe: ~`3.377s`
- `WRENFLOW_WHISPER_PARALLEL_EXECUTION=1` + `WRENFLOW_WHISPER_INTER_ORT_THREADS=2`:
  - transcribe: ~`3.846s`
- same + disabled memory pattern:
  - transcribe: ~`3.566s`
- forcing only the encoder session to `GraphOptimizationLevel::Level2`:
  - single diagnostic run looked a bit better,
  - repeated average still landed around `~2.887s`

Practical conclusion:

- the default ORT session policy is already the best of the cheap runtime knobs we tested
- `memory_pattern` should stay enabled
- `parallel_execution` should stay disabled for this path

### ORT operator profile: where encoder time actually goes

Using `WRENFLOW_WHISPER_ORT_PROFILE_DIR=/tmp/wrenflow-ort-profile`, we captured real ONNX Runtime operator traces for the current shipping bundle.

Top encoder ops by total duration:

- `DynamicQuantizeMatMul`: ~`833ms`
- `MatMul`: ~`813ms`
- `MatMulIntegerToFloat`: ~`288ms`
- `Softmax`: ~`149ms`
- `ConvInteger`: ~`103ms`

Representative hot nodes:

- `/conv2/Conv_quant_kernel_time`: ~`82.9ms`
- `/layers.5/self_attn/MatMul_kernel_time`: ~`57.6ms`
- then a long tail of attention/feed-forward matmuls in roughly `13-17ms` chunks

This is the strongest current explanation for why ONNX is still slow even after the obvious cleanup:

- the bottleneck is the quantized CPU encoder matmul path itself
- not preprocessing
- not the decode loop
- not a single pathological node
- and not a missing Apple toggle we forgot to flip

The main remaining ONNX-specific avenue would be to reduce the cost of this quantized encoder matmul stack, likely through a different graph/quantization strategy rather than more session-builder tuning.

### Static encoder quantization on real recordings

We built a more aggressive ONNX candidate by:

1. exporting the official `openai/whisper-large-v3-turbo` ONNX bundle,
2. running `quant_pre_process()` on the encoder,
3. statically quantizing the encoder with calibration data from real local `.ogg` recordings,
4. leaving the decoder and decoder-with-past models dynamically quantized.

This is now reproducible via:

```bash
mise run static-quantize-whisper-encoder
```

#### Static encoder result

Focused repeated release benchmark (`current` vs `static-encoder`) on the same saved recording:

- current shipping bundle:
  - load: ~`1.179s`
  - prewarm: ~`2.220s`
  - transcribe: ~`2.532s`
- static encoder bundle:
  - load: ~`0.926s`
  - prewarm: ~`2.201s`
  - transcribe: ~`2.453s`

This is the first ONNX variant that beats the current shipping bundle on warm transcription latency **without changing backend**.

#### Static encoder quality check

We also compared `current` vs `static-encoder` on saved real Whisper history entries from `history.sqlite`:

- current average similarity: ~`0.556`
- static average similarity: ~`0.517`

So the static encoder bundle is faster, but currently shows a measurable quality regression on the few saved Whisper samples we tested.

#### Aggressive all-matmul static encoder

We also tried a more aggressive variant with `MatMulConstBOnly = false`, i.e. quantizing more encoder matmuls:

- load: ~`0.906s`
- prewarm: ~`2.525s`
- transcribe: ~`2.206s`

However this variant is not product-usable: on the benchmark sample it collapsed to garbage output like `B.`. So it proves the encoder can go faster, but only by destroying transcription quality.

#### Operator-level difference

The regular static encoder profile changed the hot path from:

- `DynamicQuantizeMatMul`
- `MatMulIntegerToFloat`
- `ConvInteger`

to:

- `QLinearMatMul`
- `QLinearConv`
- `BiasGelu`

but it still retained a large amount of plain `MatMul` time in the encoder. That explains why it helps, but does not completely transform the latency story.

## Practical Conclusion

The ONNX bottleneck is not primarily caused by:

- our decoder bookkeeping,
- missing Apple acceleration toggles,
- or using a community bundle instead of an official export.

The core issue is that `Whisper large-v3-turbo` under the current ONNX runtime strategy remains encoder-heavy and slow for short dictation on macOS.

More specifically:

1. The runtime always pays for a `128 x 3000` encoder pass.
2. The shipping bundle is already the “better” ONNX variant because it is aggressively quantized.
3. Our official export is cleaner but materially heavier until we quantize it.
4. ORT CoreML EP does not rescue this graph and actually makes it worse.

## Recommendation

If Wrenflow wants a fast macOS Whisper path, the next serious candidates are:

1. a different backend (`whisper.cpp`, likely the best fit for the Rust-first architecture), or
2. a dedicated Apple-native path (`WhisperKit` / CoreML), if macOS-only speed matters more than backend portability.

If we still want to keep ONNX alive, the only sensible next step is:

3. build a proper custom quantized Whisper export pipeline and benchmark it in release conditions against the current community bundle.

## whisper.cpp baseline on the same recording

We also measured `whisper.cpp` with Metal on the exact same saved recording used for the ONNX spike.

Command shape:

```bash
/tmp/wrenflow-whispercpp-build/bin/whisper-cli \
  -m /tmp/wrenflow-whispercpp-models/ggml-large-v3-turbo.bin \
  -f /tmp/wrenflow-whispercpp-recording.wav \
  -l auto \
  -t 8 \
  -nt
```

The most relevant results:

- `large-v3-turbo`, `-nt`
  - load: ~`678.51 ms`
  - mel: ~`3.89 ms`
  - sample: ~`26.64 ms`
  - encode: ~`1434.74 ms`
  - decode: ~`9.66 ms`
  - batchd: ~`159.14 ms`
  - total: ~`2338.55 ms`

- `large-v3-turbo-q5_0`, `-nt`
  - load: ~`268.79 ms`
  - mel: ~`3.52 ms`
  - sample: ~`54.67 ms`
  - encode: ~`1633.80 ms`
  - decode: ~`20.09 ms`
  - batchd: ~`238.89 ms`
  - total: ~`2248.35 ms`

Compared to our best ONNX shipping bundle after preprocessing fixes:

- feature / mel are already in the same ballpark (`~1.5 ms` vs `~3-4 ms`)
- decoder-side work is also much closer than expected
  - ONNX decode loop: roughly `~220-300 ms`
  - `whisper.cpp` non-encoder decode path: `sample + decode + batchd ~= 195 ms`
- the large remaining gap is overwhelmingly in the encoder
  - ONNX encoder: `~2.2-2.3 s`
  - `whisper.cpp` encoder: `~1.43 s`

This is the most important practical conclusion from the cross-backend baseline: our ONNX path is not losing mostly in token sampling or cache bookkeeping anymore. It is losing in encoder execution.

## Reproducible local pipeline

The repo now has a full local spike pipeline:

```bash
mise run export-whisper-onnx
mise run quantize-whisper-onnx
mise run static-quantize-whisper-encoder
mise run benchmark-whisper-onnx
```

To capture and summarize raw ORT operator profiles:

```bash
WRENFLOW_WHISPER_ORT_PROFILE_DIR=/tmp/wrenflow-ort-profile \
  mise exec -- cargo test -p wrenflow-core --release debug_local_whisper_stage_timings -- --ignored --nocapture

mise run summarize-whisper-ort-profile -- /tmp/wrenflow-ort-profile
```

To try the quantized export in the real app model directory:

```bash
mise run install-whisper-onnx-export
```

This creates a timestamped backup of the existing Whisper model directory before replacing it.

## Safety guard rails

Heavy Whisper spike tasks now refuse to start unless there is enough free disk space and no other heavy Whisper spike job is already running.

- export: defaults to requiring `80 GiB` free
- dynamic quantization: defaults to requiring `60 GiB` free
- static encoder quantization: defaults to requiring `90 GiB` free
- benchmark/install helpers: defaults to requiring `20 GiB` free

All heavy jobs are serialized through a shared lock to avoid the exact failure mode that previously led to runaway `/tmp` growth, swap expansion, and a macOS watchdog panic.

Useful commands:

```bash
mise run cleanup-whisper-spike
WRENFLOW_SPIKE_MIN_FREE_GB=120 mise run static-quantize-whisper-encoder
```

## Concrete performance ideas stolen from WhisperKit / whisper.cpp

These are the useful ideas we can actually reuse:

1. Quantized artifacts are first-class.
   - `whisper.cpp` distributes pre-converted runtime-specific weights instead of asking the app to infer from a generic float export.
   - Our `official export + INT8` result strongly supports doing the same for Wrenflow ONNX.

2. Prewarm is an explicit product concept.
   - `WhisperKit` treats specialization/prewarm as a separate lifecycle phase and times it explicitly.
   - We now expose optional stage timing traces in `WRENFLOW_WHISPER_TRACE_TIMINGS=1` to make this visible in the app/runtime path too.

3. Benchmark the warm path in release mode.
   - Both `WhisperKit` and `whisper.cpp` are tuned around actual runtime execution, not debug-only harnesses.
   - Wrenflow now has a dedicated benchmark entrypoint for release-mode ONNX comparisons.

4. Avoid pretending generic Apple acceleration will save a bad graph.
   - `whisper.cpp` uses its own Metal/CoreML path.
   - `WhisperKit` uses fully Apple-native CoreML models with explicit compute-unit choices.
   - ORT `CoreML EP` on our current graph was empirically worse, so this is not a “flip the switch” optimization.

5. Separate component-specialization policy matters.
   - `WhisperKit` uses different compute-unit choices for mel, audio encoder, and text decoder.
   - We cannot copy that directly without changing backend, but it is a strong hint that a monolithic ORT path is structurally disadvantaged on macOS.

## What we can realistically port from whisper.cpp into ONNX

These are the concrete `whisper.cpp` wins that still look portable into an ONNX-based Wrenflow path:

1. Treat the encoder as the real optimization target.
   - The baseline above shows the remaining backend gap is mostly encoder time.
   - So further ONNX work should stop focusing on decoder loop tweaks and concentrate on encoder graph representation.

2. Keep the decoder path conservative and optimize the encoder much more aggressively.
   - `whisper.cpp` results show that faster total runtime does not require a radically different decoder.
   - In ONNX terms, this suggests a mixed strategy:
     - aggressive quantization / graph surgery for the encoder,
     - more conservative decoder and decoder-with-past treatment to protect quality.

3. Prefer pre-baked runtime-native artifacts over generic exports.
   - `whisper.cpp` ships runtime-oriented weights, not “convert at app startup” style artifacts.
   - ONNX should do the same:
     - exported once,
     - optimized offline,
     - quantized offline,
     - validated offline,
     - then shipped as a first-class artifact.

4. Bias for the no-timestamps dictation path.
   - `whisper.cpp -nt` is materially faster than the default CLI mode.
   - Wrenflow already mostly follows this idea product-wise, but ONNX validation and benchmarks should continue to target the `no_timestamps` path as the primary success metric.

5. Use operator-level evidence, not session-builder folklore.
   - `whisper.cpp` establishes that the decoder side is already reasonably healthy.
   - ORT profiling establishes that our remaining cost sits in encoder `DynamicQuantizeMatMul` / `MatMul` / `MatMulIntegerToFloat`.
   - So the next ONNX wins are likely to come from encoder-specific graph/quantization changes, not from more thread/execution-mode flag tuning.

## What we probably cannot port from whisper.cpp without leaving ONNX

These `whisper.cpp` advantages do not appear meaningfully portable into our current ORT path:

1. Its Metal-native execution path.
   - That is backend-specific, not an export trick.

2. Its model format and kernel stack.
   - GGML/GGUF quantization plus custom kernels are a different execution model than ORT.

3. Its scheduler wins from owning the whole graph runtime.
   - ORT still decides how the ONNX graph executes.
   - We can influence the graph, but not recreate `whisper.cpp`'s exact execution engine inside ORT.

## Best remaining ONNX-specific moves

Given everything above, the best remaining ONNX moves look like:

1. encoder-first mixed quantization
   - more selective than `static-allmatmul`,
   - more aggressive than the current `static-encoder`,
   - specifically targeted at the hot encoder `MatMul` / `DynamicQuantizeMatMul` path.

2. encoder-specific graph surgery / export shaping
   - try to reduce the amount of expensive plain `MatMul` still left after static quantization,
   - while keeping enough float precision to avoid the quality collapse we saw in `allmatmul`.

3. validate every candidate against both:
   - repeated warm release timings,
   - saved Whisper history quality checks.

## May 16 follow-up: trim path and recalibration failures

Two more practical checks were run after the earlier static-encoder experiments:

1. A conservative trim-before-Whisper path was added in the Rust backend.
   - It removes leading/trailing silence only for the Whisper path.
   - This is safe product hygiene, but it does **not** move the main latency needle.
   - On the saved sample used for benchmarking, it removed only ~20 ms of audio.
   - More importantly, the current Whisper ONNX export still pads features to a fixed `3000` encoder-frame contract, so encoder cost is effectively unchanged.

2. Recalibrated static-encoder candidates were generated again with fresh offline calibration:
   - `static-r2` (2 calibration recordings)
   - `static-r8` (8 calibration recordings)

Those candidates were both bad in practice:

- `static-r2`
  - avg load: `~1.229s`
  - avg prewarm: `~7.385s`
  - avg transcribe: `~8.078s`
  - quality avg on saved Whisper history: `~0.377`

- `static-r8`
  - avg load: `~1.322s`
  - avg prewarm: `~10.427s`
  - avg transcribe: `~12.133s`
  - quality avg on saved Whisper history: `~0.409`

For comparison, the current shipping bundle on the same quality set remained:

- current shipping bundle
  - avg quality: `~0.422`

And on the repeated warm timing path it remained dramatically faster than both recalibrated static candidates.

### Interpretation

This matters because it narrows the next ONNX move further:

- The trim/VAD-inspired path from `whisperx` is still worth keeping for product correctness, but it does not solve the fixed-window encoder problem.
- The current static-encoder pipeline is fragile. Small calibration changes do not merely shift quality a bit; they can completely wreck prewarm/transcribe latency.
- So the next ONNX attempt should not be “run the same static encoder quantization again”.

The next viable ONNX-specific step is now narrower:

1. keep the current shipping bundle as baseline
2. avoid broad static encoder recalibration passes
3. target the encoder hot path more surgically:
   - fewer node classes,
   - fewer layer groups,
   - and always verify both latency and transcript quality immediately afterward

## May 16 follow-up: selective encoder quantization that actually survives

After profiling the failed broad recalibration candidates, the useful signal became:

- broad static encoder passes (`constb` over wide encoder regions) are too unstable,
- attention-heavy quantization can improve latency,
- but only when measured in a clean serial benchmark,
- and the operator profile shows **why**: over-quantizing attention introduces a very expensive `QLinearSoftmax` path.

### Measurement trap we hit

Some earlier terrible `hybrid-r8` / `mlp-r8` numbers were contaminated by running:

- latency benchmark
- and quality comparison

at the same time in separate test processes.

That contention was enough to make good candidates look catastrophically bad. The only numbers that should be trusted are the later **serial** runs.

### Hybrid hot-attention candidate

Candidate:

- mode: `hybrid_hot_attention`
- calibration recordings: `8`
- output bundle: `openai-whisper-large-v3-turbo-with-past-encoder-hybrid-r8`

Clean serial repeated release benchmark:

- current shipping bundle
  - load: `~1.216s`
  - prewarm: `~2.084s`
  - transcribe: `~2.349s`

- `hybrid-r8`
  - load: `~1.191s`
  - prewarm: `~2.185s`
  - transcribe: `~2.192s`

So this candidate is the first **cleanly reproduced** ONNX variant that improves warm transcribe latency while staying close on prewarm and load.

Quality on saved Whisper history:

- current avg similarity: `~0.422`
- `hybrid-r8` avg similarity: `~0.417`

That is a small regression, but dramatically better than the failed broad static candidates.

### Why hybrid works better than broad/static MLP-only

Operator profile for `hybrid-r8` shows the encoder hot path changes to:

- `QLinearMatMul`
- `QLinearSoftmax`
- `BiasGelu`

This explains two things:

1. selective attention quantization really can pull transcribe latency down,
2. but it is dangerous to push it too wide, because `QLinearSoftmax` becomes an obvious new hotspot.

By contrast:

- `mlp_only` stayed product-poor:
  - clean quality collapsed on at least one sample (`"You can't."`)
  - and latency was still bad
- broad recalibrated `constb` passes remained unstable and slow

### Current best ONNX direction

The best current ONNX direction is no longer “broad static encoder quantization”.

It is:

1. keep the current shipping bundle as the stable baseline
2. treat `hybrid-r8` as the current best experimental candidate
3. iterate surgically around the attention path:
   - preserve the latency win,
   - reduce the small quality regression,
   - and avoid exploding `QLinearSoftmax`

### Narrower hybrid and MLP-only follow-ups

Two narrower follow-ups were tested after `hybrid-r8`:

1. `hybrid-upper-r8`
   - hot attention layers limited to:
     - `17,18,19,22,23,27,28,29`
   - serial benchmark:
     - load: `~1.114s`
     - prewarm: `~2.365s`
     - transcribe: `~2.524s`
   - quality avg vs current:
     - current: `~0.422`
     - `hybrid-upper-r8`: `~0.311`

2. `mlp-r8`
   - mode: `mlp_only`
   - quality collapsed badly on at least one saved sample:
     - expected: `Ты можешь свой собственный экспорт сделать правильный?`
     - output: `You can't.`
   - overall quality avg:
     - current: `~0.422`
     - `mlp-r8`: `~0.324`

So the current ranking is now much clearer:

1. `current shipping bundle`
   - still the safest quality baseline
2. `hybrid-r8`
   - best current speed/quality tradeoff
3. `hybrid-upper-r8`
   - near-baseline latency, but quality too poor
4. `mlp-r8`
   - not viable
5. broad recalibrated static candidates
   - not viable

## Bucketed encoder experiment: directly attacking the 3000-frame cost

We then tested the most direct ONNX idea: reduce the encoder time axis itself instead of only changing quantization.

Important finding from graph inspection:

- the decoder path is already dynamic on `encoder_sequence_length`
- the encoder is what stays fixed at:
  - input: `128 x 3000`
  - output: `1500 x 1280`
- the main static graph artifacts are:
  - positional embedding tensor `[1500, 1280]`
  - many encoder reshape initializers containing `1500`

That meant a proof-of-concept bucket strategy was technically possible by patching:

1. encoder input/output shape metadata
2. positional embeddings
3. reshape initializers containing `1500` / `3000`
4. `config.json` / `preprocessor_config.json`

### `1024` bucket

Serial benchmark:

- load: `~1.416s`
- prewarm: `~0.701s`
- transcribe: `~0.872s`

This is the first result that shows the fixed 3000-frame encoder cost can indeed be cut very aggressively inside our ONNX path.

But quality regressed too much:

- current avg similarity: `~0.422`
- `bucket1024`: `~0.349`

It also introduced obvious lexical drift like:

- `Progress Bar`
- `Whisper Turbo`
- `hostname`
- `SSH`

Forcing `WRENFLOW_WHISPER_FORCE_LANGUAGE=ru` did **not** materially fix that drift.

### `1536` bucket

Serial benchmark:

- load: `~1.199s`
- prewarm: `~1.331s`
- transcribe: `~1.354s`

Quality:

- current avg similarity: `~0.422`
- `bucket1536`: `~0.398`

This is currently the strongest bucketed compromise:

- much faster than the full `3000` encoder path
- much better quality than `1024`
- still meaningfully more aggressive than `hybrid-r8`

### `2048` bucket

Serial benchmark:

- load: `~1.304s`
- prewarm: `~2.783s`
- transcribe: `~3.310s`

This bucket was not attractive:

- slower than current
- still showed lexical drift (`Visper`, English terms)

### Practical interpretation

Bucketing is now proven feasible and useful.

The new ranking for promising directions is:

1. `current shipping bundle`
   - stable quality baseline
2. `hybrid-r8`
   - best selective-quantization candidate
3. `bucket1536`
   - best direct attack on the fixed 3000-frame cost

The key new conclusion is:

- changing the encoder time bucket is **far more powerful** than another generic ORT tweak
- but reducing the bucket too aggressively hurts transcription quality
- `1536` currently looks like the best midpoint worth further product-level testing
