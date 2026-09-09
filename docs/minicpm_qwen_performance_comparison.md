# MiniCPM vs Qwen Performance Comparison

This note documents the initial performance validation for replacing `Qwen/Qwen2.5-VL-7B-Instruct` with `openbmb/MiniCPM-V-4_5-int4` in the Loss Prevention VLM workflow, as requested by issue `#335`. It also includes a follow-up `openbmb/MiniCPM-V-4_5` INT8 run to separate model effects from precision effects.

## Scope

- Service: Loss Prevention VLM workflow
- Camera config: `configs/camera_to_workload_vlm.json`
- MiniCPM INT4 workload config: `configs/workload_to_pipeline_vlm.json`
- MiniCPM INT8 workload config: `configs/workload_to_pipeline_vlm_minicpm_int8.json`
- Qwen workload config: `configs/workload_to_pipeline_vlm_qwen.json`
- MiniCPM INT4 results: `results/vlm-results/`
- MiniCPM INT8 results: `results/vlm-results-minicpm-int8/`
- Qwen results: `results/vlm-results-qwen/`

The comparison below uses the latest metric files generated for each run:

- MiniCPM INT4 application metrics: `results/vlm-results/vlm_application_metrics_20260909055113086917_810dc6.txt`
- MiniCPM INT4 performance metrics: `results/vlm-results/vlm_performance_metrics_20260909055113086917_810dc6.txt`
- MiniCPM INT8 application metrics: `results/vlm-results-minicpm-int8/vlm_application_metrics_20260909062412693544_214750.txt`
- MiniCPM INT8 performance metrics: `results/vlm-results-minicpm-int8/vlm_performance_metrics_20260909062412693544_214750.txt`
- Qwen application metrics: `results/vlm-results-qwen/vlm_application_metrics_20260909055751588892_609131.txt`
- Qwen performance metrics: `results/vlm-results-qwen/vlm_performance_metrics_20260909055751588892_609131.txt`

## Test Commands

MiniCPM INT4 run:

```bash
make run-lp REGISTRY=false \
  CAMERA_STREAM=camera_to_workload_vlm.json \
  WORKLOAD_DIST=workload_to_pipeline_vlm.json \
  OVMS_MODEL_NAME='openbmb/MiniCPM-V-4_5-int4' \
  RESULTS_DIR=../results/vlm-results
```

MiniCPM INT8 run:

```bash
make run-lp REGISTRY=false \
  CAMERA_STREAM=camera_to_workload_vlm.json \
  WORKLOAD_DIST=workload_to_pipeline_vlm_minicpm_int8.json \
  OVMS_MODEL_NAME='openbmb/MiniCPM-V-4_5' \
  RESULTS_DIR=../results/vlm-results-minicpm-int8
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

| Metric | MiniCPM int4 | MiniCPM int8 | Qwen int8 |
|---|---:|---:|---:|
| Request count | 2 | 2 | 2 |
| Avg inference latency, sec | 6.529 | 7.591 | 5.688 |
| Min inference latency, sec | 4.654 | 5.216 | 4.898 |
| Max inference latency, sec | 8.404 | 9.966 | 6.479 |
| Avg generated tokens | 18.0 | 18.0 | 12.5 |
| Avg prompt tokens | 106.5 | 106.5 | 117.5 |
| Avg completion tokens | 18.0 | 18.0 | 12.5 |
| Avg TPOT, sec/token | 0.380 | 0.436 | 0.454 |
| Avg throughput, tokens/sec | 2.669 | 2.309 | 2.203 |
| End-to-end verification duration, sec | 15.037 | 17.302 | 13.358 |

## Interpretation

- Migration comparison: `Qwen INT8` vs `MiniCPM INT4`
- Apples-to-apples precision comparison: `Qwen INT8` vs `MiniCPM INT8`
- Precision effect within the same model: `MiniCPM INT4` vs `MiniCPM INT8`

## Findings

- MiniCPM INT4 showed better token efficiency than Qwen INT8 in this run:
  - lower average TPOT
  - higher average token throughput
- MiniCPM INT4 did not improve average request latency over Qwen INT8 in this run:
  - MiniCPM INT4 average inference latency: `6.529 sec`
  - Qwen INT8 average inference latency: `5.688 sec`
- MiniCPM INT8 was slower than both MiniCPM INT4 and Qwen INT8 in this run:
  - MiniCPM INT8 average inference latency: `7.591 sec`
  - MiniCPM INT8 end-to-end verification duration: `17.302 sec`
- The equal-precision comparison also did not show a latency win for MiniCPM:
  - MiniCPM INT8 average inference latency: `7.591 sec`
  - Qwen INT8 average inference latency: `5.688 sec`
- Within the same MiniCPM model, INT4 outperformed INT8 on the measured latency metrics:
  - MiniCPM INT4 average inference latency: `6.529 sec`
  - MiniCPM INT8 average inference latency: `7.591 sec`

## Issue #335 Validation Status

Performance validation criteria from issue `#335`:

1. Measure and document inference latency before and after the change.
2. Average response time should demonstrate a noticeable improvement.
3. Target latency should be aligned with Order Accuracy, where feasible.

Current status:

- Criterion 1: satisfied
- Criterion 2: not satisfied by this run
- Criterion 3: not satisfied by this run

The issue description references Order Accuracy post-migration latency of approximately `3 seconds` average response time. The current Loss Prevention runs are above that target for all measured variants.

## Caveats

- Sample size is very small: only `2` VLM requests per model.
- This result is useful as an initial validation snapshot, not a stable benchmark.
- Differences in prompt length and generated token count can affect total latency.
- The `Qwen INT8` vs `MiniCPM INT4` comparison reflects the real migration configuration, but it changes both model family and precision.
- The `Qwen INT8` vs `MiniCPM INT8` comparison is cleaner for model-only analysis and still does not show a latency improvement in this run.

## Recommended Next Step

Run `5` to `10` identical passes per model with the same video, device selection, and workload pair, then compare mean and median latency before making a final performance claim in the issue.