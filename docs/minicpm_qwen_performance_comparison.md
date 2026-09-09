# MiniCPM vs Qwen Performance Comparison

This note documents the initial performance validation for replacing `Qwen/Qwen2.5-VL-7B-Instruct` with `openbmb/MiniCPM-V-4_5-int4` in the Loss Prevention VLM workflow, as requested by issue `#335`.

## Scope

- Service: Loss Prevention VLM workflow
- Camera config: `configs/camera_to_workload_vlm.json`
- MiniCPM workload config: `configs/workload_to_pipeline_vlm.json`
- Qwen workload config: `configs/workload_to_pipeline_vlm_qwen.json`
- MiniCPM results: `results/vlm-results/`
- Qwen results: `results/vlm-results-qwen/`

The comparison below uses the latest metric files generated for each run:

- MiniCPM application metrics: `results/vlm-results/vlm_application_metrics_20260909055113086917_810dc6.txt`
- MiniCPM performance metrics: `results/vlm-results/vlm_performance_metrics_20260909055113086917_810dc6.txt`
- Qwen application metrics: `results/vlm-results-qwen/vlm_application_metrics_20260909055751588892_609131.txt`
- Qwen performance metrics: `results/vlm-results-qwen/vlm_performance_metrics_20260909055751588892_609131.txt`

## Test Commands

MiniCPM run:

```bash
make run-lp REGISTRY=false \
  CAMERA_STREAM=camera_to_workload_vlm.json \
  WORKLOAD_DIST=workload_to_pipeline_vlm.json \
  OVMS_MODEL_NAME='openbmb/MiniCPM-V-4_5-int4' \
  RESULTS_DIR=../results/vlm-results
```

Qwen run:

```bash
make run-lp REGISTRY=false \
  CAMERA_STREAM=camera_to_workload_vlm.json \
  WORKLOAD_DIST=workload_to_pipeline_vlm_qwen.json \
  OVMS_MODEL_NAME='Qwen/Qwen2.5-VL-7B-Instruct' \
  RESULTS_DIR=../results/vlm-results-qwen
```

## Metrics Summary

Inference latency is taken from `event=ovms_vlm_request` entries in the application metrics files.

| Metric | MiniCPM int4 | Qwen int8 |
|---|---:|---:|
| Request count | 2 | 2 |
| Avg inference latency, sec | 6.529 | 5.688 |
| Min inference latency, sec | 4.654 | 4.898 |
| Max inference latency, sec | 8.404 | 6.479 |
| Avg generated tokens | 18.0 | 12.5 |
| Avg prompt tokens | 106.5 | 117.5 |
| Avg completion tokens | 18.0 | 12.5 |
| Avg TPOT, sec/token | 0.380 | 0.454 |
| Avg throughput, tokens/sec | 2.669 | 2.203 |
| End-to-end verification duration, sec | 15.037 | 13.358 |

## Findings

- MiniCPM showed better token efficiency than Qwen in this run:
  - lower average TPOT
  - higher average token throughput
- MiniCPM did not improve average request latency in this run:
  - MiniCPM average inference latency: `6.529 sec`
  - Qwen average inference latency: `5.688 sec`
- MiniCPM also had a slower end-to-end verification duration in this run:
  - MiniCPM: `15.037 sec`
  - Qwen: `13.358 sec`

## Issue #335 Validation Status

Performance validation criteria from issue `#335`:

1. Measure and document inference latency before and after the change.
2. Average response time should demonstrate a noticeable improvement.
3. Target latency should be aligned with Order Accuracy, where feasible.

Current status:

- Criterion 1: satisfied
- Criterion 2: not satisfied by this run
- Criterion 3: not satisfied by this run

The issue description references Order Accuracy post-migration latency of approximately `3 seconds` average response time. The current Loss Prevention runs are above that target for both models.

## Caveats

- Sample size is very small: only `2` VLM requests per model.
- This result is useful as an initial validation snapshot, not a stable benchmark.
- Differences in prompt length and generated token count can affect total latency.

## Recommended Next Step

Run `5` to `10` identical passes per model with the same video, device selection, and workload pair, then compare mean and median latency before making a final performance claim in the issue.