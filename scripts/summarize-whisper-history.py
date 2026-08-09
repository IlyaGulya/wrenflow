#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sqlite3
import statistics
import sys
from pathlib import Path


def main() -> int:
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 12
    db_path = (
        Path(os.environ["HOME"])
        / "Library/Application Support/Wrenflow/history.sqlite"
    )
    if not db_path.exists():
        print(f"history DB not found: {db_path}", file=sys.stderr)
        return 1

    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        """
        SELECT timestamp, transcript, metrics_json
        FROM pipeline_history
        ORDER BY timestamp DESC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()
    conn.close()

    whisper_rows: list[tuple[float, str, dict]] = []
    for ts, transcript, metrics_json in rows:
        try:
            metrics = json.loads(metrics_json or "{}")
        except json.JSONDecodeError:
            continue
        if metrics.get("transcription.modelId") != "whisper-large-v3-turbo-onnx":
            continue
        whisper_rows.append((float(ts), transcript or "", metrics))

    if not whisper_rows:
        print("No recent Whisper history entries found.")
        return 0

    transcribe_ms = [
        float(metrics["transcription.durationMs"])
        for _, _, metrics in whisper_rows
        if isinstance(metrics.get("transcription.durationMs"), (int, float))
    ]
    total_ms = [
        float(metrics["pipeline.totalMs"])
        for _, _, metrics in whisper_rows
        if isinstance(metrics.get("pipeline.totalMs"), (int, float))
    ]
    recording_ms = [
        float(metrics["recording.durationMs"])
        for _, _, metrics in whisper_rows
        if isinstance(metrics.get("recording.durationMs"), (int, float))
    ]

    def fmt_avg(values: list[float]) -> str:
        if not values:
            return "n/a"
        return f"{statistics.mean(values):.1f} ms"

    print("Recent Whisper runs")
    print(f"DB: {db_path}")
    print(f"Entries: {len(whisper_rows)}")
    print(f"Avg recording: {fmt_avg(recording_ms)}")
    print(f"Avg transcribe: {fmt_avg(transcribe_ms)}")
    print(f"Avg pipeline total: {fmt_avg(total_ms)}")
    print("---")

    for ts, transcript, metrics in whisper_rows:
        t_ms = metrics.get("transcription.durationMs")
        p_ms = metrics.get("pipeline.totalMs")
        r_ms = metrics.get("recording.durationMs")
        transcript = " ".join(transcript.split())
        if len(transcript) > 96:
            transcript = transcript[:93] + "..."
        print(
            f"{ts:.3f} | rec={r_ms} | tx={t_ms} | total={p_ms} | {transcript}"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
