#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_PATH="${MODELS_DIR:-/workspace/models}"
OVMS_MODELS_DIR="${OVMS_MODELS_DIR:-${MODELS_PATH}/ovms-model}"
MODEL_NAME="$1"
PRECISION="$2"
HUGGINGFACE_TOKEN="${3:-}"

ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
TARGET_DEVICE_FILE=$(grep -E '^TARGET_DEVICE=' "${ENV_FILE}" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"\r' || true)
TARGET_DEVICE="${TARGET_DEVICE:-${VLM_DEVICE:-${TARGET_DEVICE_FILE:-GPU}}}"
if [[ "${TARGET_DEVICE}" == "null" || -z "${TARGET_DEVICE}" ]]; then
    TARGET_DEVICE="GPU"
fi
CACHE_SIZE_FILE=$(grep -E '^CACHE_SIZE=' "${ENV_FILE}" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"\r' || true)
CACHE_SIZE="${OVMS_CACHE_SIZE:-${CACHE_SIZE_FILE:-4}}"
if ! echo "${CACHE_SIZE}" | grep -qE '^[0-9]+$'; then
    echo "[WARN] CACHE_SIZE must be a non-negative integer (got '${CACHE_SIZE}'). Using default 4."
    CACHE_SIZE=4
fi
TARGET_PATH="${OVMS_MODELS_DIR}/${MODEL_NAME}"

validate_model_xml() {
    local model_path="$1"
    local found_valid=0

    for xml_file in "${model_path}"/*.xml; do
        [[ -e "${xml_file}" ]] || continue

        if [[ ! -s "${xml_file}" ]]; then
            echo "[WARN] Model XML is empty: ${xml_file}"
            return 1
        fi

        if [[ "$(head -c 5 "${xml_file}" 2>/dev/null || true)" != "<?xml" ]]; then
            echo "[WARN] Model XML looks corrupt (invalid header): ${xml_file}"
            return 1
        fi

        found_valid=1
    done

    [[ "${found_valid}" -eq 1 ]]
}

check_memory_for_export() {
    local recommended_gb=64
    local total_gb=0

    if [[ -f /proc/meminfo ]]; then
        total_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
    fi

    if [[ "${total_gb}" -gt 0 && "${total_gb}" -lt "${recommended_gb}" ]]; then
        echo "[WARN] System RAM is ${total_gb} GB; ${recommended_gb} GB is recommended for safer VLM export."
        echo "[WARN] If OVMS reports model-read errors, retry export on a higher-memory machine."
    fi
}

check_model() {
    local model_path="$1"

    if [[ ! -d "${model_path}" ]]; then
        return 1
    fi

    if [[ -f "${model_path}/graph.pbtxt" ]] && ls "${model_path}"/*.xml >/dev/null 2>&1; then
        validate_model_xml "${model_path}"
    else
        return 1
    fi
}

patch_graph_paths() {
    local graph_file="$1"

    if [[ -f "$graph_file" ]] && grep -qF "${OVMS_MODELS_DIR}" "$graph_file"; then
        sed -i "s|${OVMS_MODELS_DIR}|/models|g" "$graph_file"
    fi
}

update_graph_pbtxt_device() {
    local graph_file="$1"
    local desired_device="$2"

    [[ -f "${graph_file}" ]] || return 0
    [[ -n "${desired_device}" ]] || return 0

    # Update the first device-like field in graph.pbtxt when it differs.
    local current_device
    current_device=$(grep -E '^[[:space:]]*(target_device|device)[[:space:]]*:[[:space:]]*"[^"]+"' "${graph_file}" | \
        head -1 | sed -E 's/^[[:space:]]*(target_device|device)[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/')

    [[ -n "${current_device}" ]] || return 0

    if [[ "${current_device}" != "${desired_device}" ]]; then
        sed -i -E "0,/^([[:space:]]*(target_device|device)[[:space:]]*:[[:space:]]*\")[^\"]+(\".*)$/s//\1${desired_device}\3/" "${graph_file}"
        echo "[INFO] Updated graph.pbtxt device from ${current_device} to ${desired_device}"
    fi
}

migrate_legacy_model() {
    local target_path="$1"

    if [[ -d "${target_path}" ]]; then
        return 0
    fi

    local model_leaf="${MODEL_NAME##*/}"
    local legacy_paths=(
        "${OVMS_MODELS_DIR}/${model_leaf}-ov-int8"
        "${OVMS_MODELS_DIR}/${model_leaf}-int8-ov"
        "${OVMS_MODELS_DIR}/Qwen/${model_leaf}-ov-int8"
    )

    local legacy_path
    for legacy_path in "${legacy_paths[@]}"; do
        if check_model "${legacy_path}"; then
            echo "[INFO] Legacy OVMS model found at ${legacy_path}. Migrating to ${target_path}"
            mkdir -p "$(dirname "${target_path}")"
            cp -r "${legacy_path}" "${target_path}"
            return 0
        fi
    done

    return 1
}

resolve_ov_source_model() {
    local name="$1"
    local precision="$2"
    local precision_lc

    if [[ -n "${OV_SOURCE_MODEL:-}" ]]; then
        echo "${OV_SOURCE_MODEL}"
        return 0
    fi

    if [[ "${name}" == OpenVINO/* ]]; then
        echo "${name}"
        return 0
    fi

    precision_lc=$(echo "${precision}" | tr '[:upper:]' '[:lower:]')
    case "${precision_lc}" in
        int8|fp16|int4)
            echo "OpenVINO/${name##*/}-${precision_lc}-ov"
            ;;
        *)
            echo "[ERROR] Unsupported VLM precision '${precision}'. Use one of: int8, fp16, int4 or set OV_SOURCE_MODEL explicitly." >&2
            return 1
            ;;
    esac
}

download_ov_model_snapshot() {
    local source_model="$1"
    local target_path="$2"

    export HF_TOKEN="${HUGGINGFACE_TOKEN}"
    export HUGGING_FACE_HUB_TOKEN="${HUGGINGFACE_TOKEN}"
    export HF_HUB_DISABLE_SYMLINKS_WARNING=1

    echo "[INFO] Downloading OV model snapshot: ${source_model}"
    python3 - <<'PY'
import os
from huggingface_hub import snapshot_download

source_model = os.environ["OV_SOURCE_MODEL_TO_DOWNLOAD"]
target_path = os.environ["OV_TARGET_PATH"]
token = os.environ.get("HUGGINGFACE_TOKEN") or None

snapshot_download(
    repo_id=source_model,
    local_dir=target_path,
    token=token,
    local_dir_use_symlinks=False,
)
PY
}

generate_graph_pbtxt() {
    local graph_file="$1"
    local target_device="$2"
    local cache_size="$3"

    cat > "${graph_file}" <<EOF
input_stream: "HTTP_REQUEST_PAYLOAD:input"
output_stream: "HTTP_RESPONSE_PAYLOAD:output"

node: {
  name: "LLMExecutor"
  calculator: "HttpLLMCalculator"
  input_stream: "LOOPBACK:loopback"
  input_stream: "HTTP_REQUEST_PAYLOAD:input"
  input_side_packet: "LLM_NODE_RESOURCES:llm"
  output_stream: "LOOPBACK:loopback"
  output_stream: "HTTP_RESPONSE_PAYLOAD:output"
  input_stream_info: {
    tag_index: 'LOOPBACK:0',
    back_edge: true
  }
  node_options: {
      [type.googleapis.com / mediapipe.LLMCalculatorOptions]: {
          pipeline_type: VLM_CB,
          models_path: "./",
          plugin_config: '{}',
          enable_prefix_caching:  true,
          cache_size: ${cache_size},
          max_num_batched_tokens: 8192,
          max_num_seqs: 4,
          device: "${target_device}",
      }
  }
  input_stream_handler {
    input_stream_handler: "SyncSetInputStreamHandler",
    options {
      [mediapipe.SyncSetInputStreamHandlerOptions.ext] {
        sync_set {
          tag_index: "LOOPBACK:0"
        }
      }
    }
  }
}
EOF
}

export_model() {
    local source_model
    source_model=$(resolve_ov_source_model "${MODEL_NAME}" "${PRECISION}")

    if [[ ! -d "${TARGET_PATH}" || -z "$(ls -A "${TARGET_PATH}" 2>/dev/null || true)" ]]; then
        check_memory_for_export
        mkdir -p "${TARGET_PATH}"
        export OV_SOURCE_MODEL_TO_DOWNLOAD="${source_model}"
        export OV_TARGET_PATH="${TARGET_PATH}"
        download_ov_model_snapshot "${source_model}" "${TARGET_PATH}"
    else
        echo "[INFO] OV model directory already has content at ${TARGET_PATH}, skipping snapshot download"
    fi

    generate_graph_pbtxt "${TARGET_PATH}/graph.pbtxt" "${TARGET_DEVICE}" "${CACHE_SIZE}"
}

generate_ovms_config() {
    mkdir -p "${OVMS_MODELS_DIR}"
    cat > "${OVMS_MODELS_DIR}/config.json" <<EOF
{
    "model_config_list": [],
    "mediapipe_config_list": [
        {
            "name": "${MODEL_NAME}",
            "base_path": "${MODEL_NAME}"
        }
    ]
}
EOF
}

mkdir -p "${OVMS_MODELS_DIR}"

if check_model "${TARGET_PATH}"; then
    echo "[INFO] OVMS VLM model already exists at ${TARGET_PATH}, skipping export."
    patch_graph_paths "${TARGET_PATH}/graph.pbtxt"
    update_graph_pbtxt_device "${TARGET_PATH}/graph.pbtxt" "${TARGET_DEVICE}"
    generate_ovms_config
    exit 0
fi

if migrate_legacy_model "${TARGET_PATH}"; then
    echo "[INFO] Using migrated legacy model at ${TARGET_PATH}."
    patch_graph_paths "${TARGET_PATH}/graph.pbtxt"
    update_graph_pbtxt_device "${TARGET_PATH}/graph.pbtxt" "${TARGET_DEVICE}"
    generate_ovms_config
    exit 0
fi

export_model

if ! check_model "${TARGET_PATH}"; then
    echo "[ERROR] OVMS export did not produce a valid model at ${TARGET_PATH}" >&2
    exit 1
fi

patch_graph_paths "${TARGET_PATH}/graph.pbtxt"
update_graph_pbtxt_device "${TARGET_PATH}/graph.pbtxt" "${TARGET_DEVICE}"
generate_ovms_config

echo "[INFO] OVMS VLM model is ready at ${TARGET_PATH}"