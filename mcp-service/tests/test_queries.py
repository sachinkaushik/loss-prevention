"""Unit tests for the LP query helpers over the durable store."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import queries
from events import make_age_estimate, make_loss_event
from store import DurableEventStore


class QueryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = DurableEventStore(
            str(Path(self.directory.name) / "lp.sqlite"), "loss_prevention", "store_001"
        )
        loss = [
            ("hidden_items", "lane-1", 1000, "r1"),
            ("fake_scan_detection", "lane-1", 2000, "r2"),
            ("product_switching", "lane-2", 3000, "r3"),
        ]
        for scenario, lane, ts, ref in loss:
            self.store.append(make_loss_event("store_001", scenario, lane, ref_id=ref, ts_ms=ts))
        ages = [
            ("18-25", "lane-1", 1500, "a1"),
            ("18-25", "lane-2", 2500, "a2"),
            ("0-18", "lane-2", 3500, "a3"),
        ]
        for age_range, lane, ts, ref in ages:
            self.store.append(make_age_estimate("store_001", age_range, lane, ref_id=ref, ts_ms=ts))

    def tearDown(self):
        self.store.close()
        self.directory.cleanup()

    def test_loss_history_filters_by_scenario_and_lane(self):
        self.assertEqual(len(queries.loss_history(self.store)), 3)
        self.assertEqual(len(queries.loss_history(self.store, lane="lane-1")), 2)
        self.assertEqual(
            [r["ref_id"] for r in queries.loss_history(self.store, scenario="product_switching")],
            ["r3"],
        )

    def test_loss_history_filters_by_time_range(self):
        rows = queries.loss_history(self.store, start_ms=1500, end_ms=3200)
        self.assertEqual([r["ref_id"] for r in rows], ["r2", "r3"])

    def test_age_range_counts_sorted_with_optional_lane(self):
        self.assertEqual(
            queries.age_range_counts(self.store),
            [{"age_range": "0-18", "detections": 1}, {"age_range": "18-25", "detections": 2}],
        )
        self.assertEqual(
            queries.age_range_counts(self.store, lane="lane-1"),
            [{"age_range": "18-25", "detections": 1}],
        )

    def test_loss_event_count_and_lanes(self):
        self.assertEqual(queries.loss_event_count(self.store), 3)
        self.assertEqual(queries.loss_event_count(self.store, lane="lane-1"), 2)
        self.assertEqual(queries.lanes(self.store), ["lane-1", "lane-2"])


if __name__ == "__main__":
    unittest.main()
