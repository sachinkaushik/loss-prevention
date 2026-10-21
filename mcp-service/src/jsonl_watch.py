"""Background watcher that tails pipeline JSONL output into the durable log.

Polls `results/rs-*.jsonl`, reads only newline-terminated records, and persists a
per-file byte offset + sampling window in SQLite so restarts resume without
duplicates. Files from earlier runs are ignored unless already being tracked:
a file is picked up only if its mtime is at/after the current run marker
(`.lp_mcp_run_started_ms`, written by `make run-lp`) and the watcher start time.
VLM runs produce no `rs-*.jsonl`, so the watcher simply stays idle.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from collections.abc import Callable
from glob import glob
from typing import Any

import jsonl_ingest
from store import DurableEventStore

MARKER_NAME = ".lp_mcp_run_started_ms"

log = logging.getLogger("lp.jsonl_watch")


class JsonlWatcher:
    def __init__(
        self,
        store: DurableEventStore,
        results_dir: str,
        camera_config_path: str,
        lane: str,
        record_age: Callable[..., Any],
        record_loss: Callable[..., Any],
        sample_seconds: float = 1.0,
        poll_seconds: float = 2.0,
        start_ms: int | None = None,
    ) -> None:
        self.store = store
        self.results_dir = results_dir
        self.camera_config_path = camera_config_path
        self.lane = lane
        self.record_age = record_age
        self.record_loss = record_loss
        self.sample_ns = int(sample_seconds * 1_000_000_000)
        self.poll_seconds = poll_seconds
        self.start_ms = start_ms if start_ms is not None else int(time.time() * 1000)
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._config_warned = False

    def _cutoff_ms(self) -> int:
        try:
            with open(os.path.join(self.results_dir, MARKER_NAME), encoding="utf-8") as handle:
                marker = int(handle.read().strip())
        except (OSError, ValueError):
            marker = 0
        return max(marker, self.start_ms)

    def _camera_map(self) -> dict[int, dict[str, Any]] | None:
        try:
            with open(self.camera_config_path, encoding="utf-8") as handle:
                config = json.load(handle)
        except (OSError, json.JSONDecodeError) as exc:
            if not self._config_warned:
                log.warning("Camera config unavailable (%s); waiting.", exc)
                self._config_warned = True
            return None
        self._config_warned = False
        return jsonl_ingest.camera_index_map(config)

    def poll_once(self) -> tuple[int, int]:
        """Ingest any new complete records; returns (age_count, loss_count)."""
        files = sorted(glob(os.path.join(self.results_dir, "rs-*.jsonl")))
        if not files:
            return 0, 0
        cam_map = self._camera_map()
        if cam_map is None:
            return 0, 0
        cutoff = self._cutoff_ms()
        total_age = total_loss = 0
        for path in files:
            try:
                size = os.path.getsize(path)
                mtime_ms = int(os.path.getmtime(path) * 1000)
            except OSError:
                continue
            state = self.store.get_ingest_offset(path)
            if state is None:
                if mtime_ms < cutoff:
                    continue
                state = (0, None)
            offset, last_window = state
            if size == offset:
                continue
            branch = jsonl_ingest.branch_index_from_filename(path)
            camera = cam_map.get(branch) if branch is not None else None
            if not camera:
                continue
            try:
                new_offset, last_window, n_age, n_loss = jsonl_ingest.ingest_file(
                    path, offset, last_window, camera, self.lane, self.sample_ns,
                    self.record_age, self.record_loss,
                )
            except OSError:
                continue
            if new_offset != offset or state[1] != last_window:
                self.store.set_ingest_offset(path, new_offset, last_window)
            total_age += n_age
            total_loss += n_loss
        return total_age, total_loss

    def run(self) -> None:
        log.info("Watching %s for pipeline metadata (lane %s).", self.results_dir, self.lane)
        while not self._stop.is_set():
            try:
                n_age, n_loss = self.poll_once()
                if n_age or n_loss:
                    log.info("Ingested %d age estimates, %d loss events.", n_age, n_loss)
            except Exception:  # keep the watcher alive; the MCP server must stay up
                log.exception("JSONL watcher poll failed")
            self._stop.wait(self.poll_seconds)

    def start(self) -> threading.Thread:
        self._thread = threading.Thread(target=self.run, name="lp-jsonl-watch", daemon=True)
        self._thread.start()
        return self._thread

    def stop(self, timeout: float | None = None) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout)
