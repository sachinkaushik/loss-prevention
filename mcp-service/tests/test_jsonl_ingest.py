"""Unit tests for the JSONL importer parsing/aggregation logic."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import jsonl_ingest


class JsonlIngestTests(unittest.TestCase):
    def test_bucket_age_boundaries(self):
        cases = {10: "0-18", 17: "0-18", 18: "18-25", 24: "18-25", 25: "25-35",
                 34: "25-35", 40: "35-45", 55: "45-60", 60: "60+", 73: "60+"}
        for age, label in cases.items():
            self.assertEqual(jsonl_ingest.bucket_age(age), label)

    def test_branch_index_from_filename(self):
        self.assertEqual(jsonl_ingest.branch_index_from_filename("rs-1_1__3_2026.jsonl"), 0)
        self.assertEqual(jsonl_ingest.branch_index_from_filename("rs-2_1__6_2026.jsonl"), 1)
        self.assertIsNone(jsonl_ingest.branch_index_from_filename("other.jsonl"))

    def test_camera_index_map(self):
        config = {"lane_config": {"cameras": [
            {"camera_id": "cam1", "workloads": ["asc_obj_detection_age_prediction_face_detection"]},
            {"camera_id": "cam2", "workloads": ["hidden_items"]},
        ]}}
        mapping = jsonl_ingest.camera_index_map(config)
        self.assertEqual(mapping[0]["camera_id"], "cam1")
        self.assertEqual(mapping[1]["workloads"], ["hidden_items"])

    def test_aggregate_age_dedups_by_track_with_median(self):
        objects = [
            {"id": 7, "age": {"label": "40"}, "gender": {"label": "Male"}},
            {"id": 7, "age": {"label": "44"}, "gender": {"label": "Male"}},
            {"id": 7, "age": {"label": "42"}, "gender": {"label": "Male"}},
            {"id": 9, "age": {"label": "20"}, "gender": {"label": "Female"}},
            {"id": 9, "age": {"label": "22"}, "gender": {"label": "Female"}},
        ]
        result = jsonl_ingest.aggregate_age(objects)
        self.assertEqual(set(result), {"7", "9"})
        self.assertEqual(result["7"]["median_age"], 42)
        self.assertEqual(result["7"]["age_range"], "35-45")
        self.assertEqual(result["7"]["gender"], "male")
        self.assertEqual(result["9"]["age_range"], "18-25")

    def test_aggregate_loss_tracks_distinct(self):
        objects = [{"id": 1}, {"id": 1}, {"id": 2}, {"detection": {}}]
        self.assertEqual(jsonl_ingest.aggregate_loss_tracks(objects), ["1", "2"])

    def test_iter_objects_skips_blank_and_bad_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rs-1_1__1_2026.jsonl"
            path.write_text(
                json.dumps({"objects": [{"id": 1, "age": {"label": "30"}}]}) + "\n"
                "\n"
                "not-json\n"
                + json.dumps({"objects": [{"id": 2}]}) + "\n",
                encoding="utf-8",
            )
            objects = list(jsonl_ingest.iter_objects(path))
        self.assertEqual([o.get("id") for o in objects], [1, 2])

    def test_sampled_objects_keeps_one_record_per_window(self):
        one_second = 1_000_000_000
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rs-1_1__1_2026.jsonl"
            lines = [
                {"timestamp": 0, "objects": [{"id": 1}]},
                {"timestamp": 300_000_000, "objects": [{"id": 2}]},   # same 0s window -> dropped
                {"timestamp": 1_200_000_000, "objects": [{"id": 3}]},  # next 1s window -> kept
                {"timestamp": 1_900_000_000, "objects": [{"id": 4}]},  # same 1s window -> dropped
            ]
            path.write_text("\n".join(json.dumps(line) for line in lines) + "\n", encoding="utf-8")
            kept = [o["id"] for o in jsonl_ingest.sampled_objects(path, one_second)]
            every = [o["id"] for o in jsonl_ingest.sampled_objects(path, 0)]
        self.assertEqual(kept, [1, 3])
        self.assertEqual(every, [1, 2, 3, 4])


if __name__ == "__main__":
    unittest.main()
