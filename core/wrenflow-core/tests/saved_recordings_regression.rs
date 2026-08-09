use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc;
use std::time::Duration;
use std::time::Instant;

use serde_json::Value;
use wrenflow_core::history::HistoryEntry;
use wrenflow_core::model_management::{default_parakeet_model, whisper_large_v3_turbo_model};
use wrenflow_core::transcription_local::{LocalTranscriptionEngine, LocalTranscriptionError};
use wrenflow_core::HistoryStore;

const PARAKEET_MODEL_ID: &str = "parakeet-tdt-0.6b-v3-onnx";
const MAX_HISTORY_DELTA_SECS: f64 = 0.5;
const FIXTURE_ROOT_ENV: &str = "WRENFLOW_RECORDINGS_FIXTURE_DIR";

struct RecordingMatch {
    path: PathBuf,
    transcript: String,
    duration_secs: f64,
}

fn fixture_root() -> Result<PathBuf, String> {
    std::env::var_os(FIXTURE_ROOT_ENV)
        .map(PathBuf::from)
        .ok_or_else(|| {
            format!("{FIXTURE_ROOT_ENV} must point to an immutable Wrenflow app-support fixture")
        })
}

fn history_db_path() -> Result<PathBuf, String> {
    Ok(fixture_root()?.join("history.sqlite"))
}

fn model_dir(model_directory_name: &str) -> Result<PathBuf, String> {
    Ok(fixture_root()?.join("models").join(model_directory_name))
}

fn recordings_dir() -> Result<PathBuf, String> {
    Ok(fixture_root()?.join("recordings"))
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."))
}

fn configure_test_runtime_env() {
    let ort_lib_dir = repo_root().join("vendor/onnxruntime/lib");
    std::env::set_var("DYLD_LIBRARY_PATH", &ort_lib_dir);
}

fn initialize_onnx_runtime() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let ort_dylib = repo_root().join("vendor/onnxruntime/lib/libonnxruntime.dylib");
        if !ort_dylib.exists() {
            return Err(format!(
                "missing ONNX Runtime dylib at {}",
                ort_dylib.display()
            ));
        }

        let _ = ort::init_from(&ort_dylib)
            .map_err(|e| format!("load ONNX Runtime from {}: {e}", ort_dylib.display()))?
            .commit();
    }

    Ok(())
}

fn decode_ogg_to_f32_samples(path: &Path) -> Result<Vec<f32>, String> {
    let output = Command::new("ffmpeg")
        .args([
            "-v",
            "error",
            "-i",
            path.to_str()
                .ok_or_else(|| "recording path is not valid UTF-8".to_string())?,
            "-f",
            "f32le",
            "-ac",
            "1",
            "-ar",
            "16000",
            "pipe:1",
        ])
        .output()
        .map_err(|e| format!("failed to run ffmpeg: {e}"))?;

    if !output.status.success() {
        return Err(format!(
            "ffmpeg failed for {}: {}",
            path.display(),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    if output.stdout.len() % std::mem::size_of::<f32>() != 0 {
        return Err(format!(
            "decoded sample buffer length {} is not divisible by {}",
            output.stdout.len(),
            std::mem::size_of::<f32>()
        ));
    }

    Ok(output
        .stdout
        .chunks_exact(std::mem::size_of::<f32>())
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect())
}

fn recording_duration_secs(path: &Path) -> Result<f64, String> {
    let output = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            path.to_str()
                .ok_or_else(|| "recording path is not valid UTF-8".to_string())?,
        ])
        .output()
        .map_err(|e| format!("failed to run ffprobe: {e}"))?;

    if !output.status.success() {
        return Err(format!(
            "ffprobe failed for {}: {}",
            path.display(),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let value = String::from_utf8_lossy(&output.stdout);
    value.trim().parse::<f64>().map_err(|e| {
        format!(
            "failed to parse ffprobe duration for {}: {e}",
            path.display()
        )
    })
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
        .map(|token| match token {
            "100" => "сто".to_string(),
            _ => token.to_string(),
        })
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

fn recording_timestamp_secs(path: &Path) -> Option<f64> {
    let stem = path.file_stem()?.to_str()?;
    let millis = stem.strip_prefix("recording_")?.parse::<u64>().ok()?;
    Some(millis as f64 / 1000.0)
}

fn parakeet_history_entry(entry: &HistoryEntry) -> bool {
    if entry.transcript.trim().is_empty() {
        return false;
    }

    let Ok(metrics) = serde_json::from_str::<Value>(&entry.metrics_json) else {
        return false;
    };
    metrics.get("transcription.modelId").and_then(Value::as_str) == Some(PARAKEET_MODEL_ID)
}

fn discover_recording_matches() -> Result<Vec<RecordingMatch>, String> {
    let history_db_path = history_db_path()?;
    let recordings_dir = recordings_dir()?;
    if !history_db_path.is_file() {
        return Err(format!(
            "fixture history database is missing at {}",
            history_db_path.display()
        ));
    }
    if !recordings_dir.is_dir() {
        return Err(format!(
            "fixture recordings directory is missing at {}",
            recordings_dir.display()
        ));
    }

    let history = HistoryStore::open(&history_db_path)
        .map_err(|e| format!("open {}: {e}", history_db_path.display()))?
        .load_all()
        .map_err(|e| format!("load history entries: {e}"))?;

    let recording_files: Vec<(f64, PathBuf)> = std::fs::read_dir(&recordings_dir)
        .map_err(|e| format!("read {}: {e}", recordings_dir.display()))?
        .filter_map(|entry| entry.ok().map(|item| item.path()))
        .filter_map(|path| recording_timestamp_secs(&path).map(|ts| (ts, path)))
        .collect();

    let mut matches = Vec::new();
    for entry in history.iter().filter(|entry| parakeet_history_entry(entry)) {
        let Some((recording_ts, path)) = recording_files.iter().min_by(|a, b| {
            let a_delta = (a.0 - entry.timestamp).abs();
            let b_delta = (b.0 - entry.timestamp).abs();
            a_delta
                .partial_cmp(&b_delta)
                .unwrap_or(std::cmp::Ordering::Equal)
        }) else {
            continue;
        };

        if (*recording_ts - entry.timestamp).abs() > MAX_HISTORY_DELTA_SECS {
            continue;
        }

        let duration_secs = recording_duration_secs(path)?;
        matches.push(RecordingMatch {
            path: path.clone(),
            transcript: entry.transcript.clone(),
            duration_secs,
        });
    }

    matches.sort_by(|a, b| a.path.cmp(&b.path));
    matches.dedup_by(|a, b| a.path == b.path);
    Ok(matches)
}

#[test]
#[ignore = "requires an explicit immutable WRENFLOW_RECORDINGS_FIXTURE_DIR"]
fn transcribes_saved_parakeet_recordings_from_fixture() {
    let matches = discover_recording_matches().expect("discover saved recording matches");
    assert!(
        !matches.is_empty(),
        "fixture contains no matched Parakeet history and recording entries"
    );

    let short_cases: Vec<&RecordingMatch> = matches
        .iter()
        .filter(|item| item.duration_secs < 1.0)
        .take(3)
        .collect();
    let transcript_cases: Vec<&RecordingMatch> = matches
        .iter()
        .filter(|item| item.duration_secs >= 1.0)
        .take(3)
        .collect();

    assert!(
        !short_cases.is_empty() || !transcript_cases.is_empty(),
        "expected at least one local regression candidate"
    );

    let model = default_parakeet_model();
    let model_dir = model_dir(&model.directory_name).expect("resolve fixture model directory");
    assert!(
        model_dir.is_dir(),
        "fixture Parakeet model directory does not exist at {}",
        model_dir.display()
    );

    let short_cases: Vec<RecordingMatch> = short_cases.into_iter().map(clone_match).collect();
    let transcript_cases: Vec<RecordingMatch> =
        transcript_cases.into_iter().map(clone_match).collect();
    let (tx, rx) = mpsc::channel();

    std::thread::spawn(move || {
        let result =
            run_saved_recordings_regression(model, model_dir, short_cases, transcript_cases);
        let _ = tx.send(result);
    });

    match rx.recv_timeout(Duration::from_secs(90)) {
        Ok(Ok(())) => {}
        Ok(Err(message)) => panic!("{message}"),
        Err(_) => panic!(
            "saved recordings regression timed out while loading/transcribing the local model"
        ),
    }
}

fn clone_match(item: &RecordingMatch) -> RecordingMatch {
    RecordingMatch {
        path: item.path.clone(),
        transcript: item.transcript.clone(),
        duration_secs: item.duration_secs,
    }
}

fn run_saved_recordings_regression(
    model: wrenflow_core::model_management::ModelInfo,
    parakeet_model_dir: PathBuf,
    short_cases: Vec<RecordingMatch>,
    transcript_cases: Vec<RecordingMatch>,
) -> Result<(), String> {
    configure_test_runtime_env();
    initialize_onnx_runtime()?;
    eprintln!("loading model from {}", parakeet_model_dir.display());
    let mut engine = LocalTranscriptionEngine::new(&model);
    engine
        .initialize(&parakeet_model_dir, None)
        .map_err(|e| format!("load local Parakeet model: {e}"))?;
    eprintln!("prewarming model");
    engine
        .prewarm()
        .map_err(|e| format!("prewarm local Parakeet model: {e}"))?;
    eprintln!("model ready");

    for case in &short_cases {
        eprintln!("checking short recording {}", case.path.display());
        let samples = decode_ogg_to_f32_samples(&case.path)
            .map_err(|e| format!("decode {}: {e}", case.path.display()))?;
        let error = engine
            .transcribe(&samples, None)
            .expect_err("short saved recording should fail before transcription");
        if !matches!(error, LocalTranscriptionError::AudioTooShort) {
            return Err(format!(
                "expected AudioTooShort for {}, got {error}",
                case.path.display()
            ));
        }
    }

    for case in &transcript_cases {
        eprintln!("checking transcript {}", case.path.display());
        let samples = decode_ogg_to_f32_samples(&case.path)
            .map_err(|e| format!("decode {}: {e}", case.path.display()))?;
        let started = Instant::now();
        let transcript = engine
            .transcribe(&samples, None)
            .map_err(|e| format!("transcribe {}: {e}", case.path.display()))?;
        eprintln!(
            "{} => [parakeet {:?}] {}",
            case.path.display(),
            started.elapsed(),
            transcript
        );

        let similarity = transcript_regression_similarity(&case.transcript, &transcript);
        if similarity < 0.65 {
            return Err(format!(
                "transcript regression mismatch for {} (similarity {:.3})\nexpected history: {}\nactual: {}",
                case.path.display(),
                similarity,
                case.transcript,
                transcript
            ));
        }
    }

    let whisper_model = whisper_large_v3_turbo_model();
    let whisper_model_dir = model_dir(&whisper_model.directory_name)?;
    if !whisper_model_dir.exists() || transcript_cases.is_empty() {
        return Ok(());
    }

    let whisper_case = &transcript_cases[0];
    eprintln!("loading whisper model from {}", whisper_model_dir.display());
    let mut whisper_engine = LocalTranscriptionEngine::new(&whisper_model);
    whisper_engine
        .initialize(&whisper_model_dir, None)
        .map_err(|e| format!("load local Whisper model: {e}"))?;
    eprintln!("prewarming whisper model");
    whisper_engine
        .prewarm()
        .map_err(|e| format!("prewarm local Whisper model: {e}"))?;
    eprintln!("whisper model ready");

    let whisper_samples = decode_ogg_to_f32_samples(&whisper_case.path)
        .map_err(|e| format!("decode {}: {e}", whisper_case.path.display()))?;
    let started = Instant::now();
    let whisper_transcript = whisper_engine
        .transcribe(&whisper_samples, None)
        .map_err(|e| {
            format!(
                "transcribe {} with Whisper: {e}",
                whisper_case.path.display()
            )
        })?;
    eprintln!(
        "{} => [whisper {:?}] {}",
        whisper_case.path.display(),
        started.elapsed(),
        whisper_transcript
    );
    let whisper_similarity =
        transcript_regression_similarity(&whisper_case.transcript, &whisper_transcript);
    if whisper_similarity < 0.65 {
        return Err(format!(
            "whisper transcript regression mismatch for {} (similarity {:.3})\nexpected history: {}\nactual: {}",
            whisper_case.path.display(),
            whisper_similarity,
            whisper_case.transcript,
            whisper_transcript
        ));
    }

    Ok(())
}
