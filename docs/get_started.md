# Loss Prevention Get Started

This guide gives the shortest path to run the Loss Prevention service locally, using the current default VLM configuration and the existing config pairs in `configs/`.

## Prerequisites

- Ubuntu 24.04 or newer
- Docker
- Make
- Python 3
- Intel GPU or CPU runtime set up for your target configuration

Optional environment variables:

```bash
export HTTP_PROXY=<http-proxy>
export HTTPS_PROXY=<https-proxy>
export NO_PROXY=localhost,127.0.0.1,rabbitmq,minio-service,rtsp-streamer,ovms-vlm
```

## Clone And Enter The Repo

```bash
git clone -b <release-or-tag> --single-branch https://github.com/intel-retail/loss-prevention
cd loss-prevention
```

## Default Run

The default Loss Prevention VLM setup keeps `Qwen/Qwen2.5-VL-7B-Instruct` as the runtime default.

Headless run:

```bash
make run-lp
```

Visual run:

```bash
RENDER_MODE=1 DISPLAY=:0 make run-lp
```

Stop the stack:

```bash
make down-lp
```

## Download Models Explicitly

If you want to prepare models before the first run:

```bash
make download-models REGISTRY=false
```

This builds and uses the local downloader scripts instead of relying on the prebuilt registry image.

## Run The VLM Workload With Qwen

Set the credentials needed by the VLM workflow before you run it:

```bash
export MINIO_ROOT_USER=<...> MINIO_ROOT_PASSWORD=<...>
export RABBITMQ_USER=<...> RABBITMQ_PASSWORD=<...>
export GATED_MODEL=true HUGGINGFACE_TOKEN=<...>
```

Use the dedicated VLM camera and workload configs:

```bash
make run-lp \
  REGISTRY=false \
  CAMERA_STREAM=camera_to_workload_vlm.json \
  WORKLOAD_DIST=workload_to_pipeline_vlm.json \
  OVMS_MODEL_NAME='Qwen/Qwen2.5-VL-7B-Instruct'
```

Benchmark the same VLM workload after the service is up:

```bash
make benchmark \
  CAMERA_STREAM=camera_to_workload_vlm.json \
  WORKLOAD_DIST=workload_to_pipeline_vlm.json
```

## Optional: Benchmark MiniCPM

MiniCPM download and export support is available for comparison testing, but it is not the default runtime model.

MiniCPM INT4:

```bash
make download-models \
  REGISTRY=false \
  WORKLOAD_DIST=workload_to_pipeline_vlm.json \
  OVMS_MODEL_NAME='openbmb/MiniCPM-V-4_5-int4'

make run-lp \
  REGISTRY=false \
  CAMERA_STREAM=camera_to_workload_vlm.json \
  WORKLOAD_DIST=workload_to_pipeline_vlm.json \
  OVMS_MODEL_NAME='openbmb/MiniCPM-V-4_5-int4'
```

## Useful Config Pairs

- Default Loss Prevention lane:
  - `CAMERA_STREAM=camera_to_workload.json`
  - `WORKLOAD_DIST=workload_to_pipeline.json`
- VLM Loss Prevention lane:
  - `CAMERA_STREAM=camera_to_workload_vlm.json`
  - `WORKLOAD_DIST=workload_to_pipeline_vlm.json`

Run `ls configs/workload_to_pipeline_*` to confirm what your checkout provides. Passing a variant that does not exist fails fast during validation.

## Benchmarking

The main metrics to watch are FPS, end-to-end latency, CPU or GPU or NPU utilization, power, and stream density. For VLM runs, TTFT and token throughput also matter.

Stream density means the maximum concurrent streams or lane instances a system can sustain at the target FPS. In Loss Prevention, that is usually better interpreted as use-case density rather than raw stream count.

### Core Loss Prevention Benchmark

Benchmark the default six-camera lane:

```bash
make benchmark
```

Measure maximum sustainable lane density:

```bash
make benchmark-stream-density
```

### VLM Benchmark

Benchmark the VLM workload with the dedicated VLM config pair:

```bash
make benchmark \
  CAMERA_STREAM=camera_to_workload_vlm.json \
  WORKLOAD_DIST=workload_to_pipeline_vlm.json
```

### Benchmark Result Collection

Consolidate benchmark metrics:

```bash
make consolidate-metrics
cat benchmark/metrics.csv
```

Generate the utilization plot:

```bash
make plot-metrics
```

For advanced benchmark settings and tuning details, see the Benchmarking Guide:

- https://intel-retail.github.io/documentation/use-cases/loss-prevention/performance.html

## Output Files

After a run, check these locations:

- `results/` for application outputs
- `results/vlm-results/` for VLM metrics and logs
- `vlm_loss_prevention.log` for the workload handler log

