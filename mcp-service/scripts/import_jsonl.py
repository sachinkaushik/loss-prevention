"""Import non-VLM pipeline JSONL metadata into the LP durable log.

    python scripts/import_jsonl.py --results-dir ../results \
        --camera-config ../configs/camera_to_workload_asc_age_verification.json

Maps each `rs-*.jsonl` file to its camera (by branch index) using the camera
config, aggregates per tracking id, and records age_estimate / loss_event.
Idempotent: ref_ids are derived from the file name + track, so re-imports are safe.
"""

from __future__ import annotations

import argparse
import json
import os
from glob import glob
from pathlib import Path

import jsonl_ingest
from events import SCENARIOS
from tools import record_age_estimate, record_loss_event, store  # noqa: F401  (store import keeps one shared log)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-dir", default=os.getenv("LP_RESULTS_DIR", "/results"))
    parser.add_argument("--camera-config", required=True, help="Path to the camera_to_workload JSON.")
    parser.add_argument("--lane", default=os.getenv("LP_LANE", "lane-1"))
    parser.add_argument(
        "--sample-seconds", type=float, default=float(os.getenv("LP_IMPORT_SAMPLE_SECONDS", "1.0")),
        help="Keep one reading per camera per N stream-seconds (0 = no sampling).",
    )
    args = parser.parse_args()

    camera_config = json.loads(Path(args.camera_config).read_text(encoding="utf-8"))
    cam_map = jsonl_ingest.camera_index_map(camera_config)
    sample_ns = int(args.sample_seconds * 1_000_000_000)

    age_count = 0
    loss_count = 0
    for path in sorted(glob(os.path.join(args.results_dir, "rs-*.jsonl"))):
        branch = jsonl_ingest.branch_index_from_filename(path)
        camera = cam_map.get(branch) if branch is not None else None
        if not camera:
            continue
        camera_id = camera["camera_id"]
        objects = list(jsonl_ingest.sampled_objects(path, sample_ns))
        ts_ms = int(os.path.getmtime(path) * 1000)
        stem = Path(path).stem

        for track_id, info in jsonl_ingest.aggregate_age(objects).items():
            record_age_estimate(
                info["age_range"], args.lane, camera_id,
                tracking_id=track_id, gender=info["gender"],
                ref_id=f"{stem}-age-{track_id}", ts_ms=ts_ms,
            )
            age_count += 1

        scenario = next((w for w in camera["workloads"] if w in SCENARIOS), None)
        if scenario:
            for track_id in jsonl_ingest.aggregate_loss_tracks(objects):
                record_loss_event(
                    scenario, args.lane, camera_id,
                    tracking_id=track_id,
                    ref_id=f"{stem}-loss-{scenario}-{track_id}", ts_ms=ts_ms,
                )
                loss_count += 1

    print(f"imported {age_count} age estimates, {loss_count} loss events "
          f"from {args.results_dir}")


if __name__ == "__main__":
    main()
