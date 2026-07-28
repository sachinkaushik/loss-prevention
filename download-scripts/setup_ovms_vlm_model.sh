#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_PATH="${MODELS_DIR:-/workspace/models}"
OVMS_MODELS_DIR="${OVMS_MODELS_DIR:-${MODELS_PATH}/ovms-model}"
MODEL_NAME="$1"
PRECISION="$2"
HUGGINGFACE_TOKEN="${3:-}"

EXPORT_COMMIT="${OVMS_EXPORT_COMMIT:-78f8b30f82ed8dc53e6e0ba90476e480ec67e44c}"
EXPORT_BASE_URL="https://raw.githubusercontent.com/openvinotoolkit/model_server/${EXPORT_COMMIT}/demos/common/export_models"
EXPORT_SCRIPT="${SCRIPT_DIR}/export_model.py"
EXPORT_REQUIREMENTS="${SCRIPT_DIR}/export_requirements.txt"
EXPORT_VENV="${SCRIPT_DIR}/ovms-export-venv"
EXPORT_SCRIPT_SHA256="${OVMS_EXPORT_SCRIPT_SHA256:-7e419913a1ce3e93aab01d9b66b2f8ac008a2a6bce29069fe2ecd6152b323b05}"
EXPORT_REQUIREMENTS_SHA256="${OVMS_EXPORT_REQUIREMENTS_SHA256:-dedc9365ca182111fcd7478abc25a129ae70cefd6ff90b239209f3e5b11a57c2}"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
TARGET_DEVICE_FILE=$(grep -E '^TARGET_DEVICE=' "${ENV_FILE}" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"\r' || true)
TARGET_DEVICE="${TARGET_DEVICE:-${VLM_DEVICE:-${TARGET_DEVICE_FILE:-GPU}}}"
if [[ "${TARGET_DEVICE}" == "null" || -z "${TARGET_DEVICE}" ]]; then
    TARGET_DEVICE="GPU"
fi
CACHE_SIZE="${OVMS_CACHE_SIZE:-4}"
TARGET_PATH="${OVMS_MODELS_DIR}/${MODEL_NAME}"

check_model() {
    local model_path="$1"

    [[ -f "${model_path}/graph.pbtxt" ]] && ls "${model_path}"/*.xml >/dev/null 2>&1
}

verify_sha256() {
    local file_path="$1"
    local expected_sha256="$2"
    local actual_sha256

    actual_sha256=$(sha256sum "${file_path}" | awk '{print $1}')
    if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
        echo "[ERROR] SHA256 mismatch for ${file_path}" >&2
        echo "[ERROR] expected=${expected_sha256}" >&2
        echo "[ERROR] actual=${actual_sha256}" >&2
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

setup_python_env() {
    if [[ ! -f "${EXPORT_SCRIPT}" ]]; then
        echo "[INFO] Downloading OVMS export tools at commit ${EXPORT_COMMIT}"
        curl -fsSL "${EXPORT_BASE_URL}/export_model.py" -o "${EXPORT_SCRIPT}"
        curl -fsSL "${EXPORT_BASE_URL}/requirements.txt" -o "${EXPORT_REQUIREMENTS}"
    fi

    verify_sha256 "${EXPORT_SCRIPT}" "${EXPORT_SCRIPT_SHA256}"
    verify_sha256 "${EXPORT_REQUIREMENTS}" "${EXPORT_REQUIREMENTS_SHA256}"

    if [[ ! -d "${EXPORT_VENV}" || ! -f "${EXPORT_VENV}/bin/pip" ]]; then
        echo "[INFO] Creating OVMS export virtual environment"
        python3 -m venv "${EXPORT_VENV}" --clear
    fi

    # shellcheck disable=SC1091
    source "${EXPORT_VENV}/bin/activate"
    pip install -q --upgrade pip
    pip install -q -r "${EXPORT_REQUIREMENTS}"
}

export_model() {
    export HF_TOKEN="${HUGGINGFACE_TOKEN}"
    export HUGGING_FACE_HUB_TOKEN="${HUGGINGFACE_TOKEN}"

    local target_device_args=()
    if [[ -n "${TARGET_DEVICE}" && "${TARGET_DEVICE}" != "CPU" ]]; then
        target_device_args=(--target_device "${TARGET_DEVICE}")
    fi

    echo "[INFO] Exporting ${MODEL_NAME} for OVMS (precision=${PRECISION}, device=${TARGET_DEVICE:-AUTO})"
    python "${EXPORT_SCRIPT}" text_generation \
        --source_model "${MODEL_NAME}" \
        --weight-format "${PRECISION}" \
        --pipeline_type VLM_CB \
        "${target_device_args[@]}" \
        --cache_size "${CACHE_SIZE}" \
        --max_num_seqs 4 \
        --max_num_batched_tokens 8192 \
        --enable_prefix_caching True \
        --config_file_path "${OVMS_MODELS_DIR}/config.json" \
        --model_repository_path "${OVMS_MODELS_DIR}" \
        --model_name "${MODEL_NAME}"
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

setup_python_env
export_model

if ! check_model "${TARGET_PATH}"; then
    echo "[ERROR] OVMS export did not produce a valid model at ${TARGET_PATH}" >&2
    exit 1
fi

patch_graph_paths "${TARGET_PATH}/graph.pbtxt"
update_graph_pbtxt_device "${TARGET_PATH}/graph.pbtxt" "${TARGET_DEVICE}"
generate_ovms_config

echo "[INFO] OVMS VLM model is ready at ${TARGET_PATH}"