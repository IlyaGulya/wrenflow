#!/usr/bin/env python3

import json
import sys
from collections import defaultdict
from pathlib import Path


def summarize(path: Path) -> None:
    data = json.loads(path.read_text())
    by_op = defaultdict(lambda: [0, 0])
    by_name = defaultdict(lambda: [0, 0])

    for event in data:
        if event.get("cat") != "Node":
            continue
        dur = int(event.get("dur", 0))
        op_name = event.get("args", {}).get("op_name", "?")
        node_name = event.get("name", "?")
        by_op[op_name][0] += dur
        by_op[op_name][1] += 1
        by_name[node_name][0] += dur
        by_name[node_name][1] += 1

    print(f"== {path.name} ==")
    print("Top ops by total duration:")
    for op_name, (dur, count) in sorted(by_op.items(), key=lambda item: item[1][0], reverse=True)[:12]:
        print(
            f"  {op_name:28} total={dur / 1000:.3f}ms count={count:3d} avg={dur / count / 1000:.3f}ms"
        )

    print("Top nodes by total duration:")
    for node_name, (dur, count) in sorted(by_name.items(), key=lambda item: item[1][0], reverse=True)[:16]:
        print(
            f"  {node_name:72} total={dur / 1000:.3f}ms count={count:3d} avg={dur / count / 1000:.3f}ms"
        )
    print()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: summarize-whisper-ort-profile.py <profile-dir>", file=sys.stderr)
        return 1

    profile_dir = Path(sys.argv[1]).expanduser().resolve()
    if not profile_dir.is_dir():
        print(f"not a directory: {profile_dir}", file=sys.stderr)
        return 1

    files = sorted(profile_dir.glob("*.json"))
    if not files:
        print(f"no profile JSON files found in {profile_dir}", file=sys.stderr)
        return 1

    for path in files:
        summarize(path)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
