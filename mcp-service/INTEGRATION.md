# Loss Prevention MCP Service

A sensor MCP service that exposes self-checkout **loss** scenarios and
**age-range** classification from the Loss Prevention pipeline. The age mix feeds
the signage-board decision; the loss history feeds operator review.

- Service owns its SQLite event log, hub delivery, and (later) live ingestion.
- Sensor contract: `describe` + read tools only. **No subscribe/callback, no
  action tools.**

## 1. Events

Two event types share one durable, ordered log.

| Event | Payload |
|---|---|
| `loss_event` | `scenario`, `lane`, `camera_id`, `severity`, `tracking_id`, `frame`, `description` |
| `age_estimate` | `age_range`, `lane`, `camera_id`, `tracking_id`, `gender`, `frame` |

`scenario` is one of: `items_in_basket`, `hidden_items`, `fake_scan_detection`,
`multi_product_identification`, `product_switching`, `sweethearting`.

Every event is wrapped in the standard envelope:

```python
EventEnvelope(event_type, service="loss_prevention", store_id, payload,
              ref_id, ts_ms, schema_version=1)
```

### Durability and delivery
- **Log first.** `record_loss_event` / `record_age_estimate` persist to the
  service's SQLite log *before* any delivery — nothing is dropped, and the full
  run is replayable.
- **Idempotent.** `ref_id` deduplicates redelivered events (stored once).
- **Hub fan-out.** Committed loss events at/above `LP_EVENT_HUB_MIN_SEVERITY`
  are POSTed to `LP_EVENT_HUB_URL` in the agent-inbox shape (`event_id`,
  `event_type`, `occurred_at`, `data`). `store_id` stays inside `data`.
- **Replay.** `scripts/replay_events.py` streams the ordered log, optionally
  delivering (`--deliver`) at original timing (`--speed`).

## 2. MCP tools

| Tool | Params | Returns |
|---|---|---|
| `describe` | — | service info, event-type schemas, read tools, `act_tools: []`, `subscribe: disabled` |
| `Get_loss_history` | `scenario?`, `lane?`, `start_time?`, `end_time?`, `limit?` | newest matching loss events |
| `Get_age_range_counts` | `start_time?`, `end_time?`, `lane?` | counts grouped by age range |
| `Get_loss_event_count` | `scenario?`, `lane?`, `start_time?`, `end_time?` | compact count |
| `Get_lanes` | — | lanes with recorded loss activity |

Time values are ISO-8601; naive values use `LP_TIMEZONE`.

## 3. Quick start (DX walkthrough)

```bash
cd mcp-service
python3 -m venv .venv
.venv/bin/pip install -e .

# Preload demo history, then run the end-to-end query demo:
.venv/bin/python scripts/seed_demo.py
.venv/bin/python scripts/demo_e2e.py

# Run the MCP server (stdio by default; HTTP for remote agents):
.venv/bin/lp-mcp
.venv/bin/lp-mcp  # MCP_TRANSPORT=streamable-http MCP_PORT=9100 for HTTP
```

Run the tests:

```bash
.venv/bin/python -m pytest -q
```

## 4. One command up (Docker)

From the repository root:

```bash
make mcp-up           # build + start the MCP service (port 9100)
make mcp-seed         # preload demo history into the running container
make mcp-down         # stop and remove

# Clean benchmark run (durable log only, no hub fan-out):
make mcp-bench
```

Or directly with compose:

```bash
cd mcp-service
SEED_DEMO=true docker compose up --build -d
```

## 5. Configuration

| Var | Default | Meaning |
|---|---|---|
| `STORE_ID` | `store_001` | Store identity stamped on every event. |
| `MCP_TRANSPORT` | `stdio` | `stdio` \| `sse` \| `streamable-http`. |
| `MCP_HOST` / `MCP_PORT` | `0.0.0.0` / `9100` | Bind host/port for HTTP transports. |
| `LP_LOG_PATH` | `data/lp_log.sqlite` | Durable log path. |
| `LP_EVENT_HUB_URL` | — | Agent inbox URL for fan-out. |
| `LP_EVENT_DELIVERY` | `on` | `off` disables fan-out (clean benchmarks). |
| `LP_EVENT_HUB_MIN_SEVERITY` | `high` | Minimum loss severity delivered to the hub. |
| `LP_LANE_CONFIG_PATH` | `/app/lane_config.json` | Optional known-lane list. |
| `LP_TIMEZONE` | `Asia/Kolkata` | Timezone for naive ISO datetimes. |
| `SEED_DEMO` | `false` | Preload demo history at container start. |

## 6. Coding-agent walkthrough

To add a new read tool or event field:

1. Extend the schema in `src/events.py` (`LOSS_SCHEMA` / `AGE_SCHEMA`) and the
   matching builder; keep `ref_id` idempotency.
2. Add query logic in `src/queries.py` over the durable log only.
3. Expose a `@mcp.tool(annotations={"readOnlyHint": True})` in `src/tools.py`;
   never add subscribe or action tools to this sensor service.
4. Add a test in `tests/` and a row to the tool table above.

## 7. Ingestion from the pipeline

How the loss-prevention pipeline emits data depends on the workload:

- **Non-VLM workloads** (age verification, object detection/classification, loss
  scenarios) publish via `gvametapublish file-format=json-lines` to per-camera
  files `results/rs-*.jsonl`. This is the primary ingestion source.
- **VLM workload** (`lp_vlm`) publishes to RabbitMQ `object_detection` through a
  `gvapython` step; a RabbitMQ consumer can be added later for that path only.

### Import JSONL into the MCP (non-VLM)
`scripts/import_jsonl.py` maps each `rs-*.jsonl` to its camera (by branch index)
using the camera config, aggregates per tracking id, and records events:
- `age.label` (numeric) -> median per track -> bucketed `age_range` -> `age_estimate`
- a camera whose workload name is a known scenario -> `loss_event` per track

After a pipeline run (the MCP container mounts `results/` and `configs/`):

```bash
make mcp-import CAMERA_STREAM=camera_to_workload_asc_age_verification.json
```

Imports are idempotent (ref_id = file name + track), so re-running is safe. The
numeric `age.label` is bucketed into `0-18, 18-25, 25-35, 35-45, 45-60, 60+`.
