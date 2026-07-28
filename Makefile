# Copyright © 2025 Intel Corporation. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

 .PHONY: update-submodules download-models download-samples download-sample-videos build-assets-downloader run-assets-downloader build-pipeline-runner run-loss-prevention run-lp down-lp clean-images clean-containers clean-all clean-project-images validate-config validate-camera-config validate-all-configs check-models check-device check-env show-config help logs-vlm logs-all restart-vlm check-model test-api status
-include .env
export


HTTP_PROXY := $(or $(HTTP_PROXY),$(http_proxy))
HTTPS_PROXY := $(or $(HTTPS_PROXY),$(https_proxy))
export HTTP_PROXY
export HTTPS_PROXY


export PWD=$(shell pwd)
HOST_IP := $(shell ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p')
export VLM_DEVICE ?= CPU
TARGET_DEVICE ?= $(VLM_DEVICE)
export VLM_SERVICE_PORT ?= 8000
export LP_BASE_DIR=$(PWD)
export LLM_BASE_DIR=$(PWD)/models/ovms-model
export MINIO_API_HOST_PORT=4000
export MINIO_CONSOLE_HOST_PORT=4001
export LP_IP=$(HOST_IP)
export LOCAL_UID=$(id -u)
export LOCAL_GID=$(id -g)
# Default values for benchmark
PIPELINE_COUNT ?= 1
INIT_DURATION ?= 30
TARGET_FPS ?= 14.95
CONTAINER_NAMES ?= gst0
DENSITY_INCREMENT ?= 1
MKDOCS_IMAGE ?= asc-mkdocs
RESULTS_DIR ?= $(PWD)/benchmark
CAMERA_STREAM ?= camera_to_workload.json
WORKLOAD_DIST ?= workload_to_pipeline.json
VLM_CAMERA_STREAM ?= camera_to_workload_vlm.json
BATCH_SIZE_DETECT ?= 1
BATCH_SIZE_CLASSIFY ?= 1
INFERENCE_INTERVAL ?= 3
REGISTRY ?= true
DOCKER_COMPOSE ?= docker-compose.yml
STREAM_LOOP ?= true

# OVMS and VLM defaults
VLM_BACKEND ?= ovms
OVMS_ENDPOINT ?= http://ovms-vlm:8000
OVMS_MODEL_NAME ?= Qwen/Qwen2.5-VL-7B-Instruct
OVMS_IMAGE ?= $(if $(filter CPU,$(TARGET_DEVICE)),openvino/model_server:latest,openvino/model_server:latest-gpu)
OVMS_HOST_PORT ?= 8002


TAG ?= latest
LP_TAG = $(shell cat VERSION)
export LP_TAG
RENDER_MODE ?=0
REGISTRY ?= true
# Registry image references
REGISTRY_MODEL_DOWNLOADER ?= intel/model-downloader:$(LP_TAG)
REGISTRY_PIPELINE_RUNNER ?= intel/pipeline-runner-lp:$(LP_TAG)
REGISTRY_BENCHMARK ?= intel/retail-benchmark:$(LP_TAG)

VLM_LOGS_FILE ?= $(PWD)/vlm_loss_prevention.log
LP_VLM_WORKLOAD_ENABLED := $(shell python3 lp-vlm/src/workload_utils.py --camera-config configs/$(CAMERA_STREAM) --has-lp-vlm)

# Set STREAM_LOOP based on LP_VLM_WORKLOAD_ENABLED
ifeq ($(LP_VLM_WORKLOAD_ENABLED),1)
	STREAM_LOOP_VALUE := false
else
	STREAM_LOOP_VALUE := true
endif

check-models:
	@chmod +x check_models.sh
	@./check_models.sh models || true

download-models: check-models
	@if ./check_models.sh models; then \
		echo ".....Downloading models....."; \
		if [ "$(REGISTRY)" = "true" ]; then \
			$(MAKE) fetch-model-downloader; \
		else \
			$(MAKE) build-model-downloader; \
		fi; \
		$(MAKE) run-model-downloader; \
	else \
		echo ".....All models already present, skipping download....."; \
	fi

fetch-model-downloader:
	@echo "Fetching model downloader from registry..."
	docker pull $(REGISTRY_MODEL_DOWNLOADER)
	@echo "Model downloader ready"

build-model-downloader: | validate-pipeline-config
	@echo "Building model downloader"
	docker build --build-arg HTTPS_PROXY=${HTTPS_PROXY} --build-arg HTTP_PROXY=${HTTP_PROXY} -t $(REGISTRY_MODEL_DOWNLOADER) -f docker/Dockerfile.downloader .
	@echo "assets downloader completed"

build-lp-images:
	@echo "Building loss prevention images"
	docker compose -f src/$(DOCKER_COMPOSE) build

run-model-downloader:
	@echo "Running assets downloader"
	docker run --rm \
		-e HTTP_PROXY=${HTTP_PROXY} \
		-e HTTPS_PROXY=${HTTPS_PROXY} \
		-e http_proxy=${HTTP_PROXY} \
		-e https_proxy=${HTTPS_PROXY} \
		-e LOCAL_UID=$(shell id -u) \
		-e LOCAL_GID=$(shell id -g) \
		-e MODELS_DIR=/workspace/models \
		-e WORKLOAD_DIST=${WORKLOAD_DIST} \
		-e HF_HOME=/root/.cache/huggingface \
		-e HUGGINGFACE_TOKEN=${HUGGINGFACE_TOKEN} \
		-e HF_HUB_DOWNLOAD_TIMEOUT=600 \
		-v "$(shell pwd)/models:/workspace/models" \
		-v "$(shell pwd)/configs:/workspace/configs" \
		$(REGISTRY_MODEL_DOWNLOADER)
	@echo "assets downloader completed"

download-sample-videos: | validate-camera-config
	@echo "Downloading and formatting videos for all cameras in $(CAMERA_STREAM)..."
	python3 download-scripts/download-video.py --camera-config configs/$(CAMERA_STREAM) --format-script performance-tools/benchmark-scripts/format_avc_mp4.sh

update-submodules:
	@echo "Cloning performance tool repositories"
	git submodule deinit -f .
	git submodule update --init --recursive
	@echo "Submodules updated (if any present)."

check-device:
	@GRAPH="models/ovms-model/$(OVMS_MODEL_NAME)/graph.pbtxt"; \
	if [ ! -f "$$GRAPH" ]; then \
		echo "[INFO] graph.pbtxt not found, skipping device check"; \
		exit 0; \
	fi; \
	VLM_DEV=$$(jq -r '.workload_pipeline_map.lp_vlm[]? | select((.type // "" | ascii_downcase) == "vlm") | .vlm_device // empty' configs/$(WORKLOAD_DIST) 2>/dev/null | head -1 || true); \
	if [ -z "$$VLM_DEV" ] || [ "$$VLM_DEV" = "null" ]; then VLM_DEV="$(VLM_DEVICE)"; fi; \
	GRAPH_DEV=$$(grep -E '^[[:space:]]*(target_device|device)[[:space:]]*:[[:space:]]*"[^"]+"' "$$GRAPH" | head -1 | sed -E 's/^[[:space:]]*(target_device|device)[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/' || true); \
	if [ -z "$$GRAPH_DEV" ]; then \
		echo "[INFO] No target_device/device field found in $$GRAPH, skipping device update"; \
		exit 0; \
	fi; \
	if [ "$$GRAPH_DEV" = "$$VLM_DEV" ]; then \
		echo "[INFO] graph.pbtxt device already matches $$VLM_DEV"; \
	else \
		echo "[INFO] Updating graph.pbtxt device: $$GRAPH_DEV → $$VLM_DEV"; \
		sed -i -E "0,/^([[:space:]]*(target_device|device)[[:space:]]*:[[:space:]]*\")[^\"]+(\".*)$$/s//\\1$$VLM_DEV\\3/" "$$GRAPH"; \
		echo "[INFO] graph.pbtxt updated to $$VLM_DEV"; \
	fi

check-env:
	@echo "[INFO] Validating environment configuration..."
	@if [ "$(VLM_BACKEND)" != "ovms" ]; then \
		echo "[ERROR] VLM_BACKEND must be 'ovms' for the current OVMS-only VLM runtime (got: $(VLM_BACKEND))"; \
		exit 1; \
	fi
	@if [ -z "$(OVMS_ENDPOINT)" ]; then \
		echo "[ERROR] OVMS_ENDPOINT is required when VLM_BACKEND=ovms"; \
		exit 1; \
	fi
	@if [ -z "$(OVMS_MODEL_NAME)" ]; then \
		echo "[ERROR] OVMS_MODEL_NAME is required when VLM_BACKEND=ovms"; \
		exit 1; \
	fi
	@echo "[INFO] Environment configuration valid"
	@$(MAKE) --no-print-directory check-device

show-config:
	@echo "Current configuration"
	@echo "====================="
	@echo "VLM_BACKEND   = $(VLM_BACKEND)"
	@echo "VLM_DEVICE    = $(VLM_DEVICE)"
	@echo "TARGET_DEVICE = $(TARGET_DEVICE)"
	@echo "OVMS_ENDPOINT = $(OVMS_ENDPOINT)"
	@echo "OVMS_MODEL_NAME = $(OVMS_MODEL_NAME)"
	@echo "OVMS_IMAGE    = $(OVMS_IMAGE)"
	@echo "OVMS_HOST_PORT = $(OVMS_HOST_PORT)"

help:
	@echo "Loss prevention - common commands"
	@echo "================================="
	@echo "make run-lp            - Start the loss prevention stack"
	@echo "make down-lp           - Stop the stack"
	@echo "make check-env         - Validate OVMS/VLM settings"
	@echo "make check-device      - Sync graph.pbtxt device"
	@echo "make show-config       - Print effective OVMS/VLM config"
	@echo "make status            - Show compose service status"
	@echo "make logs-vlm          - Follow OVMS logs"
	@echo "make logs-all          - Follow all service logs"
	@echo "make restart-vlm       - Restart OVMS service"
	@echo "make check-model       - Query OVMS model status"
	@echo "make test-api          - Quick OVMS endpoint test"

status:
	@docker compose -f src/$(DOCKER_COMPOSE) ps

logs-vlm:
	@echo "Showing OVMS VLM logs (Ctrl+C to exit)..."
	@docker logs -f ovms-vlm

logs-all:
	@echo "Showing all service logs (Ctrl+C to exit)..."
	@docker compose -f src/$(DOCKER_COMPOSE) logs -f

restart-vlm:
	@echo "Restarting OVMS VLM service..."
	@docker compose -f src/$(DOCKER_COMPOSE) restart ovms-vlm

check-model:
	@echo "Checking OVMS model status on localhost:$(OVMS_HOST_PORT)..."
	@curl -s "http://localhost:$(OVMS_HOST_PORT)/v1/config" | jq '."$(OVMS_MODEL_NAME)" // .' 2>/dev/null || \
		echo "OVMS not responding. Is ovms-vlm running?"

test-api:
	@echo "=== OVMS Config Endpoint ==="
	@curl -s "http://localhost:$(OVMS_HOST_PORT)/v1/config" | jq . 2>/dev/null || curl -s "http://localhost:$(OVMS_HOST_PORT)/v1/config"

run-lp: validate_workload_mapping update-submodules download-sample-videos
	@echo "Running loss prevention pipeline"
	@LOG_FILE="vlm_loss_prevention.log"; \
	mkdir -p $$(dirname $$LOG_FILE); \
	[ -f $$LOG_FILE ] || touch $$LOG_FILE; \
	if [ "$(RENDER_MODE)" != "0" ]; then \
		$(MAKE) run-render-mode; \
	else \
		$(MAKE) run; \
	fi


down-lp:	
	docker compose -f src/$(DOCKER_COMPOSE) down	
	@echo "Cleaning up VLM temporary files..."
	@rm -f vlm_loss_prevention.log
	@rm -f lp-vlm/lp-vlm.env
	@echo "VLM cleanup completed"

run: validate_workload_mapping download-sample-videos
	@echo "Setting up environment for STREAM_LOOP..."
	@mkdir -p results results/vlm-results
	@LOG_FILE="vlm_loss_prevention.log"; \
	    mkdir -p $$(dirname $$LOG_FILE); \
	    [ -f $$LOG_FILE ] || touch $$LOG_FILE
	@if [ "$(REGISTRY)" = "true" ]; then \
		echo "##############Using registry mode - fetching pipeline runner..."; \
		LOCAL_UID=$(shell id -u) LOCAL_GID=$(shell id -g) LP_VLM_WORKLOAD_ENABLED=$(LP_VLM_WORKLOAD_ENABLED) STREAM_LOOP=$(STREAM_LOOP_VALUE) BATCH_SIZE_DETECT=$(BATCH_SIZE_DETECT) BATCH_SIZE_CLASSIFY=$(BATCH_SIZE_CLASSIFY) INFERENCE_INTERVAL=$(INFERENCE_INTERVAL) docker compose -f src/$(DOCKER_COMPOSE) up -d; \
	else \
		LOCAL_UID=$(shell id -u) LOCAL_GID=$(shell id -g) LP_VLM_WORKLOAD_ENABLED=$(LP_VLM_WORKLOAD_ENABLED) STREAM_LOOP=$(STREAM_LOOP_VALUE) BATCH_SIZE_DETECT=$(BATCH_SIZE_DETECT) BATCH_SIZE_CLASSIFY=$(BATCH_SIZE_CLASSIFY) INFERENCE_INTERVAL=$(INFERENCE_INTERVAL) docker compose -f src/$(DOCKER_COMPOSE) up --build -d; \
	fi

run-render-mode: validate_workload_mapping download-sample-videos
	@if [ -z "$(DISPLAY)" ] || ! echo "$(DISPLAY)" | grep -qE "^:[0-9]+(\.[0-9]+)?$$"; then \
		echo "ERROR: Invalid or missing DISPLAY environment variable."; \
		echo "Please set DISPLAY in the format ':<number>' (e.g., ':0')."; \
		echo "Usage: make <target> DISPLAY=:<number>"; \
		echo "Example: make $@ DISPLAY=:0"; \
		exit 1; \
	fi
	@echo "Using DISPLAY=$(DISPLAY)"
	@echo "Using config file: configs/$(CAMERA_STREAM)"
	@echo "Using workload config: configs/$(WORKLOAD_DIST)"
	@xhost +local:docker
	@LOG_FILE="vlm_loss_prevention.log"; \
		mkdir -p $$(dirname $$LOG_FILE); \
		[ -f $$LOG_FILE ] || touch $$LOG_FILE
	@if [ "$(REGISTRY)" = "true" ]; then \
		echo "##############Using registry mode - fetching pipeline runner..."; \
		mkdir -p results results/vlm-results; \
		LOCAL_UID=$(shell id -u) LOCAL_GID=$(shell id -g) RENDER_MODE=1  LP_VLM_WORKLOAD_ENABLED=$(LP_VLM_WORKLOAD_ENABLED) STREAM_LOOP=$(STREAM_LOOP_VALUE) CAMERA_STREAM=$(CAMERA_STREAM) WORKLOAD_DIST=$(WORKLOAD_DIST) BATCH_SIZE_DETECT=$(BATCH_SIZE_DETECT) BATCH_SIZE_CLASSIFY=$(BATCH_SIZE_CLASSIFY) INFERENCE_INTERVAL=$(INFERENCE_INTERVAL) docker compose -f src/$(DOCKER_COMPOSE) up -d; \
	else \
		docker compose -f src/$(DOCKER_COMPOSE) build; \
		mkdir -p results results/vlm-results; \
		LOCAL_UID=$(shell id -u) LOCAL_GID=$(shell id -g) RENDER_MODE=1 LP_VLM_WORKLOAD_ENABLED=$(LP_VLM_WORKLOAD_ENABLED) STREAM_LOOP=$(STREAM_LOOP_VALUE) CAMERA_STREAM=$(CAMERA_STREAM) WORKLOAD_DIST=$(WORKLOAD_DIST) BATCH_SIZE_DETECT=$(BATCH_SIZE_DETECT) BATCH_SIZE_CLASSIFY=$(BATCH_SIZE_CLASSIFY) INFERENCE_INTERVAL=$(INFERENCE_INTERVAL) docker compose -f src/$(DOCKER_COMPOSE) up --build -d; \
	fi	
	$(MAKE) clean-images

fetch-benchmark:
	@echo "Fetching benchmark image from registry..."
	docker pull $(REGISTRY_BENCHMARK)
	@echo "Benchmark image ready"

build-benchmark:
	@echo "Building benchmark Docker image..."$(REGISTRY)
	@if [ "$(REGISTRY)" = "true" ]; then \
		$(MAKE) fetch-benchmark; \
	else \
		cd performance-tools && $(MAKE) build-benchmark-docker; \
	fi

benchmark: build-benchmark download-sample-videos download-models
	mkdir -p $$(dirname $(VLM_LOGS_FILE)); \
	[ -f $(VLM_LOGS_FILE) ] || touch $(VLM_LOGS_FILE); \
	cd performance-tools/benchmark-scripts && \
	export MULTI_STREAM_MODE=1 && \
	export LP_VLM_WORKLOAD_ENABLED=$(LP_VLM_WORKLOAD_ENABLED) && \
	export STREAM_LOOP=$(STREAM_LOOP_VALUE) && \
	( \
		python3 -m venv venv && \
		. venv/bin/activate && \
		pip3 install -r requirements.txt && \
		python3 benchmark.py \
			--compose_file ../../src/$(DOCKER_COMPOSE) \
			--pipelines $(PIPELINE_COUNT) \
			--results_dir $(RESULTS_DIR) \
			$$(if [ "$(REGISTRY)" = "true" ]; then echo "--benchmark_type=reg"; fi); \
		deactivate \
	)



benchmark-stream-density: build-benchmark download-sample-videos download-models
	@if [ "$(OOM_PROTECTION)" = "0" ]; then \
        echo "╔════════════════════════════════════════════════════════════╗";\
		echo "║ WARNING                                                    ║";\
		echo "║                                                            ║";\
		echo "║ OOM Protection is DISABLED. This test may:                 ║";\
		echo "║ • Cause system instability or crashes                      ║";\
		echo "║ • Require hard reboot if system becomes unresponsive       ║";\
		echo "║ • Result in data loss in other applications                ║";\
		echo "║                                                            ║";\
		echo "║ Press Ctrl+C now to cancel, or wait 5 seconds...           ║";\
		echo "╚════════════════════════════════════════════════════════════╝";\
		sleep 5;\
    fi
	mkdir -p $$(dirname $(VLM_LOGS_FILE)); \
	[ -f $(VLM_LOGS_FILE) ] || touch $(VLM_LOGS_FILE); \
	cd performance-tools/benchmark-scripts && \
	export MULTI_STREAM_MODE=1 && \
	export STREAM_LOOP=$(STREAM_LOOP_VALUE) && \
    ( \
	python3 -m venv venv && \
	. venv/bin/activate && \
	pip3 install -r requirements.txt && \
	python3 benchmark.py \
		--compose_file ../../src/$(DOCKER_COMPOSE) \
		--init_duration $(INIT_DURATION) \
		--target_fps $(TARGET_FPS) \
		--container_names $(CONTAINER_NAMES) \
		--density_increment $(DENSITY_INCREMENT) \
		--results_dir $(RESULTS_DIR) \
		$$(if [ "$(REGISTRY)" = "true" ]; then echo "--benchmark_type=reg"; fi); \
	deactivate \
	)
	
benchmark-quickstart: download-models download-sample-videos
	@if [ "$(REGISTRY)" = "true" ]; then \
		echo "Using registry mode - skipping benchmark container build..."; \
	else \
		echo "Building benchmark container locally..."; \
		$(MAKE) build-benchmark; \
	fi
	mkdir -p $$(dirname $(VLM_LOGS_FILE)); \
	[ -f $(VLM_LOGS_FILE) ] || touch $(VLM_LOGS_FILE); \
	cd performance-tools/benchmark-scripts && \
	export MULTI_STREAM_MODE=1 && \
	export STREAM_LOOP=$(STREAM_LOOP_VALUE) && \
	( \
	python3 -m venv venv && \
	. venv/bin/activate && \
	pip3 install -r requirements.txt && \
	python3 benchmark.py --compose_file ../../src/$(DOCKER_COMPOSE) --pipelines $(PIPELINE_COUNT) --results_dir $(RESULTS_DIR) $$(if [ "$(REGISTRY)" = "true" ]; then echo "--benchmark_type=reg"; fi); \
	deactivate \
	)
	$(MAKE) consolidate-metrics

clean-images:
	@echo "Cleaning up dangling Docker images..."
	@docker image prune -f
	@echo "Cleaning up unused Docker images..."
	@docker images -f "dangling=true" -q | xargs -r docker rmi
	@echo "Dangling images cleaned up"

clean-containers:
	@echo "Cleaning up stopped containers..."
	@docker container prune -f
	@echo "Stopped containers cleaned up"

clean-all:
	@echo "Cleaning up all unused Docker resources..."
	@docker system prune -f
	@echo "Cleaning up build cache..."
	@docker builder prune -f
	@echo "All unused Docker resources cleaned up"

clean-project-images:
	@echo "Cleaning up project-specific images..."
	@docker rmi $(REGISTRY_MODEL_DOWNLOADER) $(REGISTRY_PIPELINE_RUNNER) 2>/dev/null || true
	@echo "Project images cleaned up"

docs: clean-docs
	mkdocs build
	mkdocs serve -a localhost:8008

docs-builder-image:
	docker build \
		-f Dockerfile.docs \
		-t $(MKDOCS_IMAGE) \
		.

build-docs: docs-builder-image
	docker run --rm \
		-u $(shell id -u):$(shell id -g) \
		-v $(PWD):/docs \
		-w /docs \
		$(MKDOCS_IMAGE) \
		build

serve-docs: docs-builder-image
	docker run --rm \
		-it \
		-u $(shell id -u):$(shell id -g) \
		-p 8008:8000 \
		-v $(PWD):/docs \
		-w /docs \
		$(MKDOCS_IMAGE)

clean-docs:
	rm -rf docs/

validate_workload_mapping:
	python3 src/validate-configs.py --validate-workload-mapping --camera-config configs/$(CAMERA_STREAM) --pipeline-config configs/$(WORKLOAD_DIST)
	@$(MAKE) --no-print-directory check-device

validate-pipeline-config:
	@echo "Validating pipeline configuration..."
	@python3 src/validate-configs.py --validate-pipeline --pipeline-config configs/$(WORKLOAD_DIST)

validate-camera-config:
	@echo "Validating camera configuration..."
	@python3 src/validate-configs.py --validate-camera --camera-config configs/$(CAMERA_STREAM)

validate-all-configs:
	@echo "Validating all configuration files..."
	@python3 src/validate-configs.py --validate-all

consolidate-metrics:
	cd performance-tools/benchmark-scripts && \
	( \
	python3 -m venv venv && \
	. venv/bin/activate && \
	pip install -r requirements.txt && \
	python3 consolidate_multiple_run_of_metrics.py --root_directory $(RESULTS_DIR) --output $(RESULTS_DIR)/metrics.csv && \
	deactivate \
	)

plot-metrics:
	cd performance-tools/benchmark-scripts && \
	( \
	python3 -m venv venv && \
	. venv/bin/activate && \
	pip install -r requirements.txt && \
	python3 usage_graph_plot.py --dir $(RESULTS_DIR)  && \
	deactivate \
	)
