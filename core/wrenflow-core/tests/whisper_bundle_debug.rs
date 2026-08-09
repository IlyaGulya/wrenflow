use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Instant;

use serde_json::Value;
use tempfile::tempdir;
use tokio::runtime::Builder;
use wrenflow_core::model_downloader;
use wrenflow_core::model_management::{
    whisper_large_v3_turbo_model, DownloadProgress, LocalModelState, ModelDownloadListener,
    ModelInfo, ModelRuntime,
};
use wrenflow_core::transcription_local::LocalTranscriptionEngine;
use wrenflow_core::{history::HistoryEntry, HistoryStore};

struct NoopListener;

#[derive(Debug, Clone, Copy)]
struct BenchmarkTimings {
    load_secs: f64,
    prewarm_secs: f64,
    transcribe_secs: f64,
}

impl ModelDownloadListener for NoopListener {
    fn on_progress(&self, _progress: DownloadProgress) {}

    fn on_state_changed(&self, _state: LocalModelState) {}
}

fn lite_whisper_large_v3_turbo_model() -> ModelInfo {
    ModelInfo {
        id: "lite-whisper-large-v3-turbo-onnx".to_string(),
        name: "Lite Whisper Large V3 Turbo".to_string(),
        repo_id: "onnx-community/lite-whisper-large-v3-turbo-ONNX".to_string(),
        directory_name: "lite-whisper-large-v3-turbo".to_string(),
        expected_files: vec![
            "config.json".to_string(),
            "generation_config.json".to_string(),
            "preprocessor_config.json".to_string(),
            "tokenizer.json".to_string(),
            "tokenizer_config.json".to_string(),
            "special_tokens_map.json".to_string(),
            "added_tokens.json".to_string(),
            "merges.txt".to_string(),
            "normalizer.json".to_string(),
            "vocab.json".to_string(),
            "onnx/encoder_model_int8.onnx".to_string(),
            "onnx/decoder_model_int8.onnx".to_string(),
            "onnx/decoder_with_past_model_int8.onnx".to_string(),
        ],
        generated_files: vec![],
        runtime: ModelRuntime::WhisperOnnx,
    }
}

fn decode_saved_recording(recording: &std::path::Path) -> Vec<f32> {
    let decoded = std::process::Command::new("ffmpeg")
        .args([
            "-v",
            "error",
            "-i",
            recording.to_str().expect("utf8 path"),
            "-f",
            "f32le",
            "-ac",
            "1",
            "-ar",
            "16000",
            "pipe:1",
        ])
        .output()
        .expect("run ffmpeg");
    assert!(
        decoded.status.success(),
        "ffmpeg failed: {:?}",
        decoded.status
    );
    decoded
        .stdout
        .chunks_exact(std::mem::size_of::<f32>())
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect()
}

fn normalize_transcript(text: &str) -> String {
    let mut normalized = String::with_capacity(text.len());
    let mut previous_was_space = false;

    for ch in text.chars().flat_map(char::to_lowercase) {
        let mapped = match ch {
            'ё' => 'е',
            _ if ch.is_alphanumeric() => ch,
            _ => ' ',
        };

        if mapped == ' ' {
            if !previous_was_space {
                normalized.push(' ');
            }
            previous_was_space = true;
        } else {
            normalized.push(mapped);
            previous_was_space = false;
        }
    }

    normalized.trim().to_string()
}

fn normalized_tokens(text: &str) -> Vec<String> {
    normalize_transcript(text)
        .split_whitespace()
        .map(ToString::to_string)
        .collect()
}

fn longest_common_subsequence_len(left: &[String], right: &[String]) -> usize {
    if left.is_empty() || right.is_empty() {
        return 0;
    }

    let mut dp = vec![vec![0usize; right.len() + 1]; left.len() + 1];
    for (i, left_token) in left.iter().enumerate() {
        for (j, right_token) in right.iter().enumerate() {
            dp[i + 1][j + 1] = if left_token == right_token {
                dp[i][j] + 1
            } else {
                dp[i][j + 1].max(dp[i + 1][j])
            };
        }
    }
    dp[left.len()][right.len()]
}

fn transcript_regression_similarity(expected: &str, actual: &str) -> f64 {
    let expected_tokens = normalized_tokens(expected);
    let actual_tokens = normalized_tokens(actual);
    if expected_tokens.is_empty() || actual_tokens.is_empty() {
        return 0.0;
    }

    let lcs = longest_common_subsequence_len(&expected_tokens, &actual_tokens);
    lcs as f64 / expected_tokens.len().max(actual_tokens.len()) as f64
}

fn recording_timestamp_secs(path: &std::path::Path) -> Option<f64> {
    let stem = path.file_stem()?.to_str()?;
    let millis = stem.strip_prefix("recording_")?.parse::<u64>().ok()?;
    Some(millis as f64 / 1000.0)
}

fn whisper_history_entry(entry: &HistoryEntry) -> bool {
    if entry.transcript.trim().is_empty() {
        return false;
    }

    let Ok(metrics) = serde_json::from_str::<Value>(&entry.metrics_json) else {
        return false;
    };
    metrics.get("transcription.modelId").and_then(Value::as_str)
        == Some("whisper-large-v3-turbo-onnx")
}

fn whisper_recording_matches(limit: usize) -> Vec<(std::path::PathBuf, String)> {
    let home = std::path::PathBuf::from(std::env::var("HOME").expect("HOME"));
    let history_db_path = home.join("Library/Application Support/Wrenflow/history.sqlite");
    let recordings_dir = home.join("Library/Application Support/Wrenflow/recordings");
    if !history_db_path.exists() || !recordings_dir.exists() {
        return vec![];
    }

    let history = HistoryStore::open(&history_db_path)
        .expect("open history store")
        .load_all()
        .expect("load history entries");
    let recording_files: Vec<(f64, std::path::PathBuf)> = std::fs::read_dir(&recordings_dir)
        .expect("read recordings dir")
        .filter_map(|entry| entry.ok().map(|item| item.path()))
        .filter_map(|path| recording_timestamp_secs(&path).map(|ts| (ts, path)))
        .collect();

    let mut matches = Vec::new();
    for entry in history
        .iter()
        .filter(|entry| whisper_history_entry(entry))
        .take(limit)
    {
        let Some((recording_ts, path)) = recording_files.iter().min_by(|a, b| {
            let a_delta = (a.0 - entry.timestamp).abs();
            let b_delta = (b.0 - entry.timestamp).abs();
            a_delta
                .partial_cmp(&b_delta)
                .unwrap_or(std::cmp::Ordering::Equal)
        }) else {
            continue;
        };

        if (recording_ts - entry.timestamp).abs() > 5.0 {
            continue;
        }

        matches.push((path.clone(), entry.transcript.clone()));
    }

    matches
}

fn materialize_runner_layout(
    source_dir: &std::path::Path,
    target_dir: &std::path::Path,
    encoder_name: &str,
    decoder_name: &str,
    decoder_with_past_name: &str,
) {
    std::fs::create_dir_all(target_dir.join("onnx")).expect("create runner onnx dir");

    for name in [
        "config.json",
        "generation_config.json",
        "preprocessor_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "added_tokens.json",
        "merges.txt",
        "normalizer.json",
        "vocab.json",
    ] {
        std::os::unix::fs::symlink(source_dir.join(name), target_dir.join(name))
            .unwrap_or_else(|e| panic!("symlink {name}: {e}"));
    }

    std::os::unix::fs::symlink(
        source_dir.join(encoder_name),
        target_dir.join("onnx/encoder_model_int8.onnx"),
    )
    .unwrap_or_else(|e| panic!("symlink encoder model: {e}"));
    std::os::unix::fs::symlink(
        source_dir.join(decoder_name),
        target_dir.join("onnx/decoder_model_int8.onnx"),
    )
    .unwrap_or_else(|e| panic!("symlink decoder model: {e}"));
    std::os::unix::fs::symlink(
        source_dir.join(decoder_with_past_name),
        target_dir.join("onnx/decoder_with_past_model_int8.onnx"),
    )
    .unwrap_or_else(|e| panic!("symlink decoder_with_past model: {e}"));

    symlink_external_data(
        source_dir,
        target_dir,
        encoder_name,
        "onnx/encoder_model_int8.onnx",
    );
    symlink_external_data(
        source_dir,
        target_dir,
        decoder_name,
        "onnx/decoder_model_int8.onnx",
    );
    symlink_external_data(
        source_dir,
        target_dir,
        decoder_with_past_name,
        "onnx/decoder_with_past_model_int8.onnx",
    );
}

fn symlink_external_data(
    source_dir: &std::path::Path,
    target_dir: &std::path::Path,
    source_model_name: &str,
    _target_model_relative_path: &str,
) {
    for suffix in [".onnx_data", ".data"] {
        let sidecar_name = format!("{source_model_name}{suffix}");
        let source_sidecar = source_dir.join(&sidecar_name);
        if !source_sidecar.exists() {
            continue;
        }

        let target_sidecar = target_dir.join("onnx").join(&sidecar_name);
        std::os::unix::fs::symlink(&source_sidecar, &target_sidecar)
            .unwrap_or_else(|e| panic!("symlink {}: {e}", source_sidecar.display()));
    }
}

#[cfg(target_os = "macos")]
fn benchmark_runner_layout(
    label: &str,
    layout_dir: &std::path::Path,
    samples: &[f32],
    expected_reference: &str,
) -> BenchmarkTimings {
    let model = whisper_large_v3_turbo_model();
    let mut engine = LocalTranscriptionEngine::new(&model);
    let started = Instant::now();
    engine
        .initialize(layout_dir, None)
        .unwrap_or_else(|e| panic!("load {label} whisper: {e}"));
    let load_elapsed = started.elapsed();
    let started = Instant::now();
    engine
        .prewarm()
        .unwrap_or_else(|e| panic!("prewarm {label} whisper: {e}"));
    let prewarm_elapsed = started.elapsed();
    let started = Instant::now();
    let transcript = engine
        .transcribe(samples, None)
        .unwrap_or_else(|e| panic!("transcribe with {label} whisper: {e}"));
    let transcribe_elapsed = started.elapsed();
    eprintln!(
        "[{label}] load={:?} prewarm={:?} transcribe={:?} similarity={} transcript={}",
        load_elapsed,
        prewarm_elapsed,
        transcribe_elapsed,
        normalize_transcript(&transcript) == normalize_transcript(expected_reference),
        transcript
    );
    BenchmarkTimings {
        load_secs: load_elapsed.as_secs_f64(),
        prewarm_secs: prewarm_elapsed.as_secs_f64(),
        transcribe_secs: transcribe_elapsed.as_secs_f64(),
    }
}

#[cfg(target_os = "macos")]
fn print_average(label: &str, timings: &[BenchmarkTimings]) {
    if timings.is_empty() {
        return;
    }
    let count = timings.len() as f64;
    let avg_load = timings.iter().map(|t| t.load_secs).sum::<f64>() / count;
    let avg_prewarm = timings.iter().map(|t| t.prewarm_secs).sum::<f64>() / count;
    let avg_transcribe = timings.iter().map(|t| t.transcribe_secs).sum::<f64>() / count;
    eprintln!(
        "[{label}:avg] load={avg_load:.3}s prewarm={avg_prewarm:.3}s transcribe={avg_transcribe:.3}s runs={}",
        timings.len()
    );
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "manual diagnostic for the locally installed Whisper ONNX bundle"]
fn print_local_whisper_bundle_contract() {
    use ort::session::Session;
    use std::path::PathBuf;

    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("resolve repo root");
    let ort_dylib = repo_root.join("vendor/onnxruntime/lib/libonnxruntime.dylib");
    let _ = ort::init_from(&ort_dylib)
        .expect("load ONNX Runtime")
        .commit();

    let model = PathBuf::from(std::env::var("HOME").expect("HOME"))
        .join("Library/Application Support/Wrenflow/models/whisper-large-v3-turbo/onnx/decoder_with_past_model_int8.onnx");
    let session = Session::builder()
        .expect("session builder")
        .commit_from_file(&model)
        .expect("open decoder_with_past");

    eprintln!("decoder_with_past inputs:");
    for input in session.inputs() {
        eprintln!("  {} => {:?}", input.name(), input);
    }

    eprintln!("decoder_with_past outputs:");
    for output in session.outputs() {
        eprintln!("  {} => {:?}", output.name(), output);
    }
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "manual diagnostic for the locally installed Whisper ONNX bundle"]
fn transcribe_saved_recording_with_local_whisper_bundle() {
    use std::path::PathBuf;

    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("resolve repo root");
    let ort_dylib = repo_root.join("vendor/onnxruntime/lib/libonnxruntime.dylib");
    let _ = ort::init_from(&ort_dylib)
        .expect("load ONNX Runtime")
        .commit();

    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    let model_dir = home.join("Library/Application Support/Wrenflow/models/whisper-large-v3-turbo");
    let recording =
        home.join("Library/Application Support/Wrenflow/recordings/recording_1778849124906.ogg");

    let samples = decode_saved_recording(&recording);

    let model = whisper_large_v3_turbo_model();
    let mut engine = LocalTranscriptionEngine::new(&model);
    engine.initialize(&model_dir, None).expect("load whisper");
    engine.prewarm().expect("prewarm whisper");
    let transcript = engine.transcribe(&samples, None).expect("transcribe audio");
    eprintln!("whisper transcript => {transcript}");
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "manual benchmark for comparing Whisper ONNX export variants on a saved recording"]
fn benchmark_alternative_whisper_onnx_exports() {
    use std::path::PathBuf;

    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("resolve repo root");
    let ort_dylib = repo_root.join("vendor/onnxruntime/lib/libonnxruntime.dylib");
    let _ = ort::init_from(&ort_dylib)
        .expect("load ONNX Runtime")
        .commit();

    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    let installed_model_dir =
        home.join("Library/Application Support/Wrenflow/models/whisper-large-v3-turbo");
    let recording =
        home.join("Library/Application Support/Wrenflow/recordings/recording_1778849124906.ogg");
    let samples = decode_saved_recording(&recording);
    let expected_reference =
        "Прогресс бар на Виспер Турбо при закачке почему-то несколько раз до 100 процентов дошел, а потом только начал двигаться.";

    let current_model = whisper_large_v3_turbo_model();
    let mut current_engine = LocalTranscriptionEngine::new(&current_model);
    let started = Instant::now();
    current_engine
        .initialize(&installed_model_dir, None)
        .expect("load installed whisper");
    let load_elapsed = started.elapsed();
    let started = Instant::now();
    current_engine.prewarm().expect("prewarm installed whisper");
    let prewarm_elapsed = started.elapsed();
    let started = Instant::now();
    let current_transcript = current_engine
        .transcribe(&samples, None)
        .expect("transcribe with installed whisper");
    let transcribe_elapsed = started.elapsed();
    eprintln!(
        "[current] load={:?} prewarm={:?} transcribe={:?} similarity={} transcript={}",
        load_elapsed,
        prewarm_elapsed,
        transcribe_elapsed,
        normalize_transcript(&current_transcript) == normalize_transcript(expected_reference),
        current_transcript
    );

    let lite_model = lite_whisper_large_v3_turbo_model();
    let temp_dir = tempdir().expect("temp dir");
    let runtime = Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    runtime.block_on(async {
        model_downloader::download_model(
            &lite_model,
            temp_dir.path(),
            Arc::new(NoopListener),
            Arc::new(AtomicBool::new(false)),
        )
        .await
        .expect("download lite whisper");
    });

    let mut lite_engine = LocalTranscriptionEngine::new(&lite_model);
    let started = Instant::now();
    match lite_engine.initialize(temp_dir.path(), None) {
        Ok(()) => {
            let load_elapsed = started.elapsed();
            let started = Instant::now();
            lite_engine.prewarm().expect("prewarm lite whisper");
            let prewarm_elapsed = started.elapsed();
            let started = Instant::now();
            let lite_transcript = lite_engine
                .transcribe(&samples, None)
                .expect("transcribe with lite whisper");
            let transcribe_elapsed = started.elapsed();
            eprintln!(
                "[lite] load={:?} prewarm={:?} transcribe={:?} similarity={} transcript={}",
                load_elapsed,
                prewarm_elapsed,
                transcribe_elapsed,
                normalize_transcript(&lite_transcript) == normalize_transcript(expected_reference),
                lite_transcript
            );
        }
        Err(error) => {
            eprintln!("[lite] incompatible with current runner: {error}");
        }
    }

    let own_export_dir =
        PathBuf::from("/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past");
    if own_export_dir.exists() {
        let own_layout = tempdir().expect("own export runner layout");
        materialize_runner_layout(
            &own_export_dir,
            own_layout.path(),
            "encoder_model.onnx",
            "decoder_model.onnx",
            "decoder_with_past_model.onnx",
        );
        let _ = benchmark_runner_layout(
            "own-export",
            own_layout.path(),
            &samples,
            expected_reference,
        );
    } else {
        eprintln!("[own-export] skipped: /tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past not found");
    }

    let own_quantized_export_dir =
        PathBuf::from("/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-int8");
    if own_quantized_export_dir.exists() {
        let own_quantized_layout = tempdir().expect("own quantized export runner layout");
        materialize_runner_layout(
            &own_quantized_export_dir,
            own_quantized_layout.path(),
            "encoder_model.onnx",
            "decoder_model.onnx",
            "decoder_with_past_model.onnx",
        );
        let _ = benchmark_runner_layout(
            "own-export-int8",
            own_quantized_layout.path(),
            &samples,
            expected_reference,
        );
    } else {
        eprintln!(
            "[own-export-int8] skipped: /tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-int8 not found"
        );
    }

    let own_ortopt_quantized_export_dir = PathBuf::from(
        "/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-ortopt-int8",
    );
    if own_ortopt_quantized_export_dir.exists() {
        let own_ortopt_quantized_layout =
            tempdir().expect("own ORT-optimized quantized export runner layout");
        materialize_runner_layout(
            &own_ortopt_quantized_export_dir,
            own_ortopt_quantized_layout.path(),
            "encoder_model.onnx",
            "decoder_model.onnx",
            "decoder_with_past_model.onnx",
        );
        let _ = benchmark_runner_layout(
            "own-export-ortopt-int8",
            own_ortopt_quantized_layout.path(),
            &samples,
            expected_reference,
        );
    } else {
        eprintln!(
            "[own-export-ortopt-int8] skipped: /tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-ortopt-int8 not found"
        );
    }

    let own_static_encoder_export_dir = PathBuf::from(
        "/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-encoder-static",
    );
    if own_static_encoder_export_dir.exists() {
        let own_static_encoder_layout = tempdir().expect("own static encoder export runner layout");
        materialize_runner_layout(
            &own_static_encoder_export_dir,
            own_static_encoder_layout.path(),
            "encoder_model.static_qop.onnx",
            "decoder_model.dynamic_int8.onnx",
            "decoder_with_past_model.dynamic_int8.onnx",
        );
        benchmark_runner_layout(
            "own-export-encoder-static",
            own_static_encoder_layout.path(),
            &samples,
            expected_reference,
        );
    } else {
        eprintln!(
            "[own-export-encoder-static] skipped: /tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-encoder-static not found"
        );
    }

    let community_ortopt_dir =
        PathBuf::from("/tmp/wrenflow-whisper-export/community-whisper-large-v3-turbo-ortopt");
    if community_ortopt_dir.exists() {
        let _ = benchmark_runner_layout(
            "current-ortopt",
            &community_ortopt_dir,
            &samples,
            expected_reference,
        );
    } else {
        eprintln!(
            "[current-ortopt] skipped: /tmp/wrenflow-whisper-export/community-whisper-large-v3-turbo-ortopt not found"
        );
    }
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "manual repeated benchmark for selected Whisper ONNX variants"]
fn benchmark_selected_whisper_variants_repeatedly() {
    use std::path::PathBuf;

    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("resolve repo root");
    let ort_dylib = repo_root.join("vendor/onnxruntime/lib/libonnxruntime.dylib");
    let _ = ort::init_from(&ort_dylib)
        .expect("load ONNX Runtime")
        .commit();

    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    let installed_model_dir =
        home.join("Library/Application Support/Wrenflow/models/whisper-large-v3-turbo");
    let recording =
        home.join("Library/Application Support/Wrenflow/recordings/recording_1778849124906.ogg");
    let samples = decode_saved_recording(&recording);
    let expected_reference =
        "Прогресс бар на Виспер Турбо при закачке почему-то несколько раз до 100 процентов дошел, а потом только начал двигаться.";

    let mut current_runs = Vec::new();
    for run in 0..3 {
        let current_model = whisper_large_v3_turbo_model();
        let mut current_engine = LocalTranscriptionEngine::new(&current_model);
        let started = Instant::now();
        current_engine
            .initialize(&installed_model_dir, None)
            .expect("load installed whisper");
        let load_elapsed = started.elapsed();
        let started = Instant::now();
        current_engine.prewarm().expect("prewarm installed whisper");
        let prewarm_elapsed = started.elapsed();
        let started = Instant::now();
        let current_transcript = current_engine
            .transcribe(&samples, None)
            .expect("transcribe with installed whisper");
        let transcribe_elapsed = started.elapsed();
        eprintln!(
            "[current:run{}] load={:?} prewarm={:?} transcribe={:?} similarity={} transcript={}",
            run + 1,
            load_elapsed,
            prewarm_elapsed,
            transcribe_elapsed,
            normalize_transcript(&current_transcript) == normalize_transcript(expected_reference),
            current_transcript
        );
        current_runs.push(BenchmarkTimings {
            load_secs: load_elapsed.as_secs_f64(),
            prewarm_secs: prewarm_elapsed.as_secs_f64(),
            transcribe_secs: transcribe_elapsed.as_secs_f64(),
        });
    }
    print_average("current", &current_runs);

    let community_ortopt_dir =
        PathBuf::from("/tmp/wrenflow-whisper-export/community-whisper-large-v3-turbo-ortopt");
    if community_ortopt_dir.exists() {
        let mut timings = Vec::new();
        for run in 0..3 {
            timings.push(benchmark_runner_layout(
                &format!("current-ortopt:run{}", run + 1),
                &community_ortopt_dir,
                &samples,
                expected_reference,
            ));
        }
        print_average("current-ortopt", &timings);
    }

    let own_quantized_export_dir =
        PathBuf::from("/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-int8");
    if own_quantized_export_dir.exists() {
        let mut timings = Vec::new();
        for run in 0..3 {
            let layout = tempdir().expect("own quantized export runner layout");
            materialize_runner_layout(
                &own_quantized_export_dir,
                layout.path(),
                "encoder_model.onnx",
                "decoder_model.onnx",
                "decoder_with_past_model.onnx",
            );
            timings.push(benchmark_runner_layout(
                &format!("own-export-int8:run{}", run + 1),
                layout.path(),
                &samples,
                expected_reference,
            ));
        }
        print_average("own-export-int8", &timings);
    }

    let own_ortopt_quantized_export_dir = PathBuf::from(
        "/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-ortopt-int8",
    );
    if own_ortopt_quantized_export_dir.exists() {
        let mut timings = Vec::new();
        for run in 0..3 {
            let layout = tempdir().expect("own ORT-optimized quantized export runner layout");
            materialize_runner_layout(
                &own_ortopt_quantized_export_dir,
                layout.path(),
                "encoder_model.onnx",
                "decoder_model.onnx",
                "decoder_with_past_model.onnx",
            );
            timings.push(benchmark_runner_layout(
                &format!("own-export-ortopt-int8:run{}", run + 1),
                layout.path(),
                &samples,
                expected_reference,
            ));
        }
        print_average("own-export-ortopt-int8", &timings);
    }

    let own_static_encoder_export_dir = PathBuf::from(
        "/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-encoder-static",
    );
    if own_static_encoder_export_dir.exists() {
        let mut timings = Vec::new();
        let runner_layout = tempdir().expect("static encoder export runner layout");
        materialize_runner_layout(
            &own_static_encoder_export_dir,
            runner_layout.path(),
            "encoder_model.static_qop.onnx",
            "decoder_model.dynamic_int8.onnx",
            "decoder_with_past_model.dynamic_int8.onnx",
        );
        for run in 0..3 {
            timings.push(benchmark_runner_layout(
                &format!("own-export-encoder-static:run{}", run + 1),
                runner_layout.path(),
                &samples,
                expected_reference,
            ));
        }
        print_average("own-export-encoder-static", &timings);
    }

    let own_static_encoder_allmatmul_export_dir = PathBuf::from(
        "/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-encoder-static-allmatmul",
    );
    if own_static_encoder_allmatmul_export_dir.exists() {
        let mut timings = Vec::new();
        let runner_layout = tempdir().expect("static all-matmul encoder export runner layout");
        materialize_runner_layout(
            &own_static_encoder_allmatmul_export_dir,
            runner_layout.path(),
            "encoder_model.static_qop.onnx",
            "decoder_model.dynamic_int8.onnx",
            "decoder_with_past_model.dynamic_int8.onnx",
        );
        for run in 0..3 {
            timings.push(benchmark_runner_layout(
                &format!("own-export-encoder-static-allmatmul:run{}", run + 1),
                runner_layout.path(),
                &samples,
                expected_reference,
            ));
        }
        print_average("own-export-encoder-static-allmatmul", &timings);
    }
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "manual repeated benchmark for current vs static-encoder Whisper bundle only"]
fn benchmark_current_vs_static_encoder_whisper_variants() {
    use std::path::PathBuf;

    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("resolve repo root");
    let ort_dylib = repo_root.join("vendor/onnxruntime/lib/libonnxruntime.dylib");
    let _ = ort::init_from(&ort_dylib)
        .expect("load ONNX Runtime")
        .commit();

    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    let installed_model_dir =
        home.join("Library/Application Support/Wrenflow/models/whisper-large-v3-turbo");
    let recording =
        home.join("Library/Application Support/Wrenflow/recordings/recording_1778849124906.ogg");
    let samples = decode_saved_recording(&recording);
    let expected_reference =
        "Прогресс бар на Виспер Турбо при закачке почему-то несколько раз до 100 процентов дошел, а потом только начал двигаться.";

    let mut current_runs = Vec::new();
    for run in 0..3 {
        let current_model = whisper_large_v3_turbo_model();
        let mut current_engine = LocalTranscriptionEngine::new(&current_model);
        let started = Instant::now();
        current_engine
            .initialize(&installed_model_dir, None)
            .expect("load installed whisper");
        let load_elapsed = started.elapsed();
        let started = Instant::now();
        current_engine.prewarm().expect("prewarm installed whisper");
        let prewarm_elapsed = started.elapsed();
        let started = Instant::now();
        let current_transcript = current_engine
            .transcribe(&samples, None)
            .expect("transcribe with installed whisper");
        let transcribe_elapsed = started.elapsed();
        eprintln!(
            "[current:run{}] load={:?} prewarm={:?} transcribe={:?} similarity={} transcript={}",
            run + 1,
            load_elapsed,
            prewarm_elapsed,
            transcribe_elapsed,
            normalize_transcript(&current_transcript) == normalize_transcript(expected_reference),
            current_transcript
        );
        current_runs.push(BenchmarkTimings {
            load_secs: load_elapsed.as_secs_f64(),
            prewarm_secs: prewarm_elapsed.as_secs_f64(),
            transcribe_secs: transcribe_elapsed.as_secs_f64(),
        });
    }
    print_average("current", &current_runs);

    let own_static_encoder_export_dir = PathBuf::from(
        "/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-encoder-static",
    );
    if own_static_encoder_export_dir.exists() {
        let mut timings = Vec::new();
        let runner_layout = tempdir().expect("static encoder export runner layout");
        materialize_runner_layout(
            &own_static_encoder_export_dir,
            runner_layout.path(),
            "encoder_model.static_qop.onnx",
            "decoder_model.dynamic_int8.onnx",
            "decoder_with_past_model.dynamic_int8.onnx",
        );
        for run in 0..3 {
            timings.push(benchmark_runner_layout(
                &format!("own-export-encoder-static:run{}", run + 1),
                runner_layout.path(),
                &samples,
                expected_reference,
            ));
        }
        print_average("own-export-encoder-static", &timings);
    }

    let own_static_encoder_allmatmul_export_dir = PathBuf::from(
        "/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-encoder-static-allmatmul",
    );
    if own_static_encoder_allmatmul_export_dir.exists() {
        let mut timings = Vec::new();
        let runner_layout = tempdir().expect("static all-matmul encoder export runner layout");
        materialize_runner_layout(
            &own_static_encoder_allmatmul_export_dir,
            runner_layout.path(),
            "encoder_model.static_qop.onnx",
            "decoder_model.dynamic_int8.onnx",
            "decoder_with_past_model.dynamic_int8.onnx",
        );
        for run in 0..3 {
            timings.push(benchmark_runner_layout(
                &format!("own-export-encoder-static-allmatmul:run{}", run + 1),
                runner_layout.path(),
                &samples,
                expected_reference,
            ));
        }
        print_average("own-export-encoder-static-allmatmul", &timings);
    }
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "manual repeated benchmark for the currently installed Whisper bundle only"]
fn benchmark_current_whisper_bundle_repeatedly() {
    use std::path::PathBuf;

    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("resolve repo root");
    let ort_dylib = repo_root.join("vendor/onnxruntime/lib/libonnxruntime.dylib");
    let _ = ort::init_from(&ort_dylib)
        .expect("load ONNX Runtime")
        .commit();

    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    let installed_model_dir = std::env::var_os("WRENFLOW_INSTALLED_WHISPER_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            home.join("Library/Application Support/Wrenflow/models/whisper-large-v3-turbo")
        });
    let recording =
        home.join("Library/Application Support/Wrenflow/recordings/recording_1778849124906.ogg");
    let samples = decode_saved_recording(&recording);
    let expected_reference =
        "Прогресс бар на Виспер Турбо при закачке почему-то несколько раз до 100 процентов дошел, а потом только начал двигаться.";

    let mut current_runs = Vec::new();
    for run in 0..3 {
        let current_model = whisper_large_v3_turbo_model();
        let mut current_engine = LocalTranscriptionEngine::new(&current_model);
        let started = Instant::now();
        current_engine
            .initialize(&installed_model_dir, None)
            .expect("load installed whisper");
        let load_elapsed = started.elapsed();
        let started = Instant::now();
        current_engine.prewarm().expect("prewarm installed whisper");
        let prewarm_elapsed = started.elapsed();
        let started = Instant::now();
        let current_transcript = current_engine
            .transcribe(&samples, None)
            .expect("transcribe with installed whisper");
        let transcribe_elapsed = started.elapsed();
        eprintln!(
            "[current:run{}] load={:?} prewarm={:?} transcribe={:?} similarity={} transcript={}",
            run + 1,
            load_elapsed,
            prewarm_elapsed,
            transcribe_elapsed,
            normalize_transcript(&current_transcript) == normalize_transcript(expected_reference),
            current_transcript
        );
        current_runs.push(BenchmarkTimings {
            load_secs: load_elapsed.as_secs_f64(),
            prewarm_secs: prewarm_elapsed.as_secs_f64(),
            transcribe_secs: transcribe_elapsed.as_secs_f64(),
        });
    }
    print_average("current", &current_runs);
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "manual quality comparison for current vs static-encoder Whisper bundle on saved Whisper history"]
fn compare_current_vs_static_encoder_whisper_quality() {
    use std::path::PathBuf;

    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("resolve repo root");
    let ort_dylib = repo_root.join("vendor/onnxruntime/lib/libonnxruntime.dylib");
    let _ = ort::init_from(&ort_dylib)
        .expect("load ONNX Runtime")
        .commit();

    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    let installed_model_dir = std::env::var_os("WRENFLOW_INSTALLED_WHISPER_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            home.join("Library/Application Support/Wrenflow/models/whisper-large-v3-turbo")
        });
    let own_static_encoder_export_dir = std::env::var_os("WRENFLOW_STATIC_ENCODER_EXPORT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(
                "/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-encoder-static",
            )
        });
    if !own_static_encoder_export_dir.exists() {
        eprintln!("[quality] skipped: static encoder export not found");
        return;
    }
    let candidate_label =
        std::env::var("WRENFLOW_STATIC_ENCODER_LABEL").unwrap_or_else(|_| "static".to_string());

    let runner_layout = tempdir().expect("static encoder export runner layout");
    materialize_runner_layout(
        &own_static_encoder_export_dir,
        runner_layout.path(),
        "encoder_model.static_qop.onnx",
        "decoder_model.dynamic_int8.onnx",
        "decoder_with_past_model.dynamic_int8.onnx",
    );

    let matches = whisper_recording_matches(8);
    assert!(!matches.is_empty(), "no whisper recording matches found");

    let current_model = whisper_large_v3_turbo_model();
    let static_model = whisper_large_v3_turbo_model();
    let mut current_engine = LocalTranscriptionEngine::new(&current_model);
    current_engine
        .initialize(&installed_model_dir, None)
        .expect("load installed whisper");
    current_engine.prewarm().expect("prewarm installed whisper");

    let mut static_engine = LocalTranscriptionEngine::new(&static_model);
    static_engine
        .initialize(runner_layout.path(), None)
        .expect("load static encoder whisper");
    static_engine
        .prewarm()
        .expect("prewarm static encoder whisper");

    let mut current_scores = Vec::new();
    let mut static_scores = Vec::new();

    for (path, expected_transcript) in matches {
        let samples = decode_saved_recording(&path);
        let current_transcript = match current_engine.transcribe(&samples, None) {
            Ok(transcript) => transcript,
            Err(error) if error.to_string().contains("Audio too short") => {
                eprintln!(
                    "[quality:{}] skipped short-audio case for both variants",
                    path.file_name().and_then(|n| n.to_str()).unwrap_or("?")
                );
                continue;
            }
            Err(error) => panic!("current transcribe {}: {error}", path.display()),
        };
        let static_transcript = match static_engine.transcribe(&samples, None) {
            Ok(transcript) => transcript,
            Err(error) if error.to_string().contains("Audio too short") => {
                eprintln!(
                    "[quality:{}] skipped short-audio case for static variant",
                    path.file_name().and_then(|n| n.to_str()).unwrap_or("?")
                );
                continue;
            }
            Err(error) => panic!("static transcribe {}: {error}", path.display()),
        };
        let current_similarity =
            transcript_regression_similarity(&expected_transcript, &current_transcript);
        let static_similarity =
            transcript_regression_similarity(&expected_transcript, &static_transcript);
        eprintln!(
            "[quality:{}] current={:.3} {}={:.3} expected={} current_t={} {}_t={}",
            path.file_name().and_then(|n| n.to_str()).unwrap_or("?"),
            current_similarity,
            candidate_label,
            static_similarity,
            expected_transcript,
            current_transcript,
            candidate_label,
            static_transcript
        );
        current_scores.push(current_similarity);
        static_scores.push(static_similarity);
    }

    assert!(
        !current_scores.is_empty() && !static_scores.is_empty(),
        "no non-short whisper recording matches were transcribed"
    );
    let current_avg = current_scores.iter().sum::<f64>() / current_scores.len() as f64;
    let static_avg = static_scores.iter().sum::<f64>() / static_scores.len() as f64;
    eprintln!(
        "[quality:avg] current={:.3} {}={:.3} samples={}",
        current_avg,
        candidate_label,
        static_avg,
        current_scores.len()
    );
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "manual repeated benchmark for env-specified Whisper candidate bundles"]
fn benchmark_whisper_candidate_bundles() {
    use std::path::PathBuf;

    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("resolve repo root");
    let ort_dylib = repo_root.join("vendor/onnxruntime/lib/libonnxruntime.dylib");
    let _ = ort::init_from(&ort_dylib)
        .expect("load ONNX Runtime")
        .commit();

    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    let recording =
        home.join("Library/Application Support/Wrenflow/recordings/recording_1778849124906.ogg");
    let samples = decode_saved_recording(&recording);
    let expected_reference =
        "Прогресс бар на Виспер Турбо при закачке почему-то несколько раз до 100 процентов дошел, а потом только начал двигаться.";

    let raw = std::env::var("WRENFLOW_WHISPER_CANDIDATE_DIRS")
        .expect("WRENFLOW_WHISPER_CANDIDATE_DIRS=label=/abs/path[,label=/abs/path]");
    for entry in raw.split(',').filter(|entry| !entry.trim().is_empty()) {
        let (label, dir) = entry
            .split_once('=')
            .unwrap_or_else(|| panic!("invalid candidate entry: {entry}"));
        let source_dir = PathBuf::from(dir);
        assert!(
            source_dir.exists(),
            "candidate dir does not exist: {}",
            source_dir.display()
        );
        let runner_layout = tempdir().expect("candidate runner layout");
        materialize_runner_layout(
            &source_dir,
            runner_layout.path(),
            "encoder_model.static_qop.onnx",
            "decoder_model.dynamic_int8.onnx",
            "decoder_with_past_model.dynamic_int8.onnx",
        );
        let mut timings = Vec::new();
        for run in 0..3 {
            timings.push(benchmark_runner_layout(
                &format!("{label}:run{}", run + 1),
                runner_layout.path(),
                &samples,
                expected_reference,
            ));
        }
        print_average(label, &timings);
    }
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "manual quality comparison for env-specified Whisper candidate bundles"]
fn compare_whisper_candidate_bundle_quality() {
    use std::path::PathBuf;

    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("resolve repo root");
    let ort_dylib = repo_root.join("vendor/onnxruntime/lib/libonnxruntime.dylib");
    let _ = ort::init_from(&ort_dylib)
        .expect("load ONNX Runtime")
        .commit();

    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    let installed_model_dir =
        home.join("Library/Application Support/Wrenflow/models/whisper-large-v3-turbo");
    let raw = std::env::var("WRENFLOW_WHISPER_CANDIDATE_DIRS")
        .expect("WRENFLOW_WHISPER_CANDIDATE_DIRS=label=/abs/path[,label=/abs/path]");
    let matches = whisper_recording_matches(8);
    assert!(!matches.is_empty(), "no whisper recording matches found");

    let current_model = whisper_large_v3_turbo_model();
    let mut current_engine = LocalTranscriptionEngine::new(&current_model);
    current_engine
        .initialize(&installed_model_dir, None)
        .expect("load installed whisper");
    current_engine.prewarm().expect("prewarm installed whisper");

    for entry in raw.split(',').filter(|entry| !entry.trim().is_empty()) {
        let (label, dir) = entry
            .split_once('=')
            .unwrap_or_else(|| panic!("invalid candidate entry: {entry}"));
        let source_dir = PathBuf::from(dir);
        assert!(
            source_dir.exists(),
            "candidate dir does not exist: {}",
            source_dir.display()
        );

        let runner_layout = tempdir().expect("candidate runner layout");
        materialize_runner_layout(
            &source_dir,
            runner_layout.path(),
            "encoder_model.static_qop.onnx",
            "decoder_model.dynamic_int8.onnx",
            "decoder_with_past_model.dynamic_int8.onnx",
        );

        let candidate_model = whisper_large_v3_turbo_model();
        let mut candidate_engine = LocalTranscriptionEngine::new(&candidate_model);
        candidate_engine
            .initialize(runner_layout.path(), None)
            .unwrap_or_else(|e| panic!("load {label} whisper: {e}"));
        candidate_engine
            .prewarm()
            .unwrap_or_else(|e| panic!("prewarm {label} whisper: {e}"));

        let mut current_scores = Vec::new();
        let mut candidate_scores = Vec::new();

        for (path, expected_transcript) in &matches {
            let samples = decode_saved_recording(path);
            let current_transcript = match current_engine.transcribe(&samples, None) {
                Ok(transcript) => transcript,
                Err(error) if error.to_string().contains("Audio too short") => continue,
                Err(error) => panic!("current transcribe {}: {error}", path.display()),
            };
            let candidate_transcript = match candidate_engine.transcribe(&samples, None) {
                Ok(transcript) => transcript,
                Err(error) if error.to_string().contains("Audio too short") => continue,
                Err(error) => panic!("{label} transcribe {}: {error}", path.display()),
            };
            let current_similarity =
                transcript_regression_similarity(expected_transcript, &current_transcript);
            let candidate_similarity =
                transcript_regression_similarity(expected_transcript, &candidate_transcript);
            eprintln!(
                "[quality:{label}:{}] current={:.3} candidate={:.3} expected={} current_t={} candidate_t={}",
                path.file_name().and_then(|n| n.to_str()).unwrap_or("?"),
                current_similarity,
                candidate_similarity,
                expected_transcript,
                current_transcript,
                candidate_transcript
            );
            current_scores.push(current_similarity);
            candidate_scores.push(candidate_similarity);
        }

        assert!(
            !current_scores.is_empty() && !candidate_scores.is_empty(),
            "no non-short whisper recording matches were transcribed for {label}"
        );
        let current_avg = current_scores.iter().sum::<f64>() / current_scores.len() as f64;
        let candidate_avg = candidate_scores.iter().sum::<f64>() / candidate_scores.len() as f64;
        eprintln!(
            "[quality:{label}:avg] current={:.3} candidate={:.3} samples={}",
            current_avg,
            candidate_avg,
            current_scores.len()
        );
    }
}
