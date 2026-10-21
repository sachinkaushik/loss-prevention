"""Parse non-VLM pipeline JSONL metadata (results/rs-*.jsonl) into MCP events.

Non-VLM workloads publish detections/age via `gvametapublish file-format=json-lines`
(one file per camera branch). This module holds the pure parsing/aggregation
logic; `scripts/import_jsonl.py` wires it to the durable store. RabbitMQ is only
used by the VLM workload, so it is not involved here.
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterator
from pathlib import Path
from statistics import median
from typing import Any

# Upper-exclusive bucket ceilings; ages at/above the last ceiling fall in "60+".
_AGE_BUCKETS = ((18, "0-18"), (25, "18-25"), (35, "25-35"), (45, "35-45"), (60, "45-60"))


def bucket_age(age: int) -> str:
    for ceiling, label in _AGE_BUCKETS:
        if age < ceiling:
            return label
    return "60+"


def camera_index_map(camera_config: dict[str, Any]) -> dict[int, dict[str, Any]]:
    """Map a camera's positional index to its id and workloads."""
    cameras = camera_config.get("lane_config", {}).get("cameras", [])
    return {
        index: {"camera_id": cam.get("camera_id", f"cam{index + 1}"),
                "workloads": list(cam.get("workloads", []))}
        for index, cam in enumerate(cameras)
    }


def branch_index_from_filename(path: str | Path) -> int | None:
    """rs-{branch+1}_{idx+1}__{counter}_{ts}.jsonl -> zero-based branch index."""
    match = re.match(r"rs-(\d+)_", Path(path).name)
    return int(match.group(1)) - 1 if match else None


def iter_objects(path: str | Path) -> Iterator[dict[str, Any]]:
    """Yield every detected object from a JSON-lines metadata file."""
    for _timestamp, objects in iter_records(path):
        yield from objects


def iter_records(path: str | Path) -> Iterator[tuple[int, list[dict[str, Any]]]]:
    """Yield (stream_timestamp_ns, objects) per JSON-lines record."""
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            yield int(record.get("timestamp", 0)), record.get("objects", [])


def sampled_objects(path: str | Path, sample_ns: int) -> Iterator[dict[str, Any]]:
    """Downsample by stream time: keep one record per sample window.

    gvatrack reassigns a fresh id per detection here, so per-track dedup cannot
    bound volume; sampling by the record timestamp keeps the log small while
    preserving the age distribution. sample_ns <= 0 disables sampling.
    """
    if sample_ns <= 0:
        yield from iter_objects(path)
        return
    seen_windows: set[int] = set()
    for timestamp, objects in iter_records(path):
        window = timestamp // sample_ns
        if window in seen_windows:
            continue
        seen_windows.add(window)
        yield from objects


def aggregate_age(objects: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """One age estimate per tracking id, using the median age across its frames."""
    tracks: dict[str, dict[str, Any]] = {}
    for obj in objects:
        if "age" not in obj:
            continue
        try:
            age = int(obj["age"]["label"])
        except (KeyError, TypeError, ValueError):
            continue
        track_id = str(obj.get("id", ""))
        gender = str((obj.get("gender") or {}).get("label", "unknown"))
        entry = tracks.setdefault(track_id, {"ages": [], "gender": gender})
        entry["ages"].append(age)
    result: dict[str, dict[str, Any]] = {}
    for track_id, entry in tracks.items():
        median_age = int(median(entry["ages"]))
        result[track_id] = {
            "age_range": bucket_age(median_age),
            "gender": entry["gender"].lower(),
            "median_age": median_age,
        }
    return result


def aggregate_loss_tracks(objects: list[dict[str, Any]]) -> list[str]:
    """Distinct tracking ids seen in a loss-scenario file (one event per track)."""
    return sorted({str(obj.get("id")) for obj in objects if obj.get("id") is not None})
