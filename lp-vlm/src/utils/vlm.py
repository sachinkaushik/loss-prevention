"""Vision Language Model integration for grocery item detection."""
import json
from typing import Dict, Any, Tuple
from io import BytesIO
import os
import time
import numpy as np
from PIL import Image
import requests
from pathlib import Path
from utils.config import OVMS_ENDPOINT, OVMS_MODEL_NAME, logger
from utils.prompts import *
from utils.ovms_client import OVMSVLMClient

WORKLOAD_PIPELINE_CONFIG = "/app/lp/configs/"
TARGET_WORKLOAD = "lp_vlm"  # normalized compare

_ovms_client = None


def get_ovms_client():
    global _ovms_client
    if _ovms_client is None:
        try:
            raw_model_name, _, _ = get_vlm_model_from_workload()
        except Exception as e:
            logger.warning(f"Failed to get OVMS model from config: {e}, using defaults")
            raw_model_name = OVMS_MODEL_NAME

        endpoint = os.environ.get("OVMS_ENDPOINT", OVMS_ENDPOINT)
        model_name = os.environ.get("OVMS_MODEL_NAME", raw_model_name)
        max_tokens = int(os.environ.get("VLM_MAX_TOKENS", "512"))

        logger.info(f"Initializing OVMS client with endpoint={endpoint}, model={model_name}")
        _ovms_client = OVMSVLMClient(
            endpoint=endpoint,
            model_name=model_name,
            max_new_tokens=max_tokens,
            temperature=0.0,
        )
    return _ovms_client


def extract_prompt_and_images(frame_records: Dict[str, Any], use_case: str = None) -> Tuple[str, list[np.ndarray]]:
    """Extract prompt and images from frame_records."""
    # Select prompt based on use_case
    if use_case == "decision_agent":
        prompt = AGENT_PROMPT
    else:
        # Use dynamic inventory-aware prompt if provided, otherwise fall back to generic
        dynamic_prompt = frame_records.get("dynamic_prompt")
        prompt = dynamic_prompt if dynamic_prompt else COMMON_PROMPT
    
    images = []
    
    # Extract images based on frame_records format
    if use_case == "decision_agent":
        # For decision_agent, append the JSON data to prompt
        prompt = f"{prompt}\nInput {json.dumps(frame_records.get('items', {}), indent=4)}"
    else:
        # Extract image from presigned_url
        presigned_url = frame_records.get("presigned_url", "")
        if presigned_url:
            try:
                response = requests.get(presigned_url, timeout=30)
                response.raise_for_status()
                img = Image.open(BytesIO(response.content)).convert("RGB")
                img = img.resize((640, 360))
                images.append(np.array(img))
                logger.info(f"Successfully loaded image from {presigned_url}")
            except Exception as e:
                logger.error(f"Failed to load image from {presigned_url}: {str(e)}")
    
    return prompt, images


def call_vlm(
    frame_records: Dict[str, Any],
    seed: int = 0,
    use_case: str = None,
) -> Tuple[bool, Dict[str, Any], str]:
    """Call the Vision Language Model to analyze frames using OVMS backend."""
    try:
        _ = seed  # kept for API compatibility with existing callers
        start_time = time.time()
        logger.info("Making ovms VLM call...")
        
        # Extract prompt and images
        prompt, images = extract_prompt_and_images(frame_records, use_case)            
        
        if not images and use_case != "decision_agent":
            return False, {}, "No images extracted from frame_records"

        vlm = get_ovms_client()

        output = vlm.generate(prompt, images=images)
        
        elapsed = time.time() - start_time
        logger.info("VLM call completed in %.2f seconds", elapsed)
        
        # Parse the output
        if hasattr(output, 'texts') and output.texts:
            raw_text = output.texts[0]
            
            # Try to extract JSON from response
            json_start = raw_text.find('[')
            json_end = raw_text.rfind(']')
            if json_start != -1 and json_end != -1 and json_end > json_start:
                json_str = raw_text[json_start:json_end + 1]
                try:
                    parsed = json.loads(json_str)
                    logger.info(f"vlm Script - [call_vlm] Successfully parsed JSON from extracted string: {parsed}")
                    return True, parsed, ""
                except Exception as e:
                    logger.error(f"vlm Script - [call_vlm] - Failed to parse JSON from extracted string: {e}")
                    return False, {}, f"Failed to parse JSON: {e}; content: {raw_text}"
            
            # If no JSON array, try to parse as generic response
            try:
                parsed = json.loads(raw_text)
                return True, parsed, ""
            except Exception as e:
                logger.error(f"vlm Script - [call_vlm] - Failed to parse JSON from raw text: {e}")
                return True, {"raw_response": raw_text}, ""
        else:
            return False, {}, "No output from VLM model"
    
    except Exception as e:
        error_msg = f"Unexpected error: {str(e)}"
        logger.error(error_msg)
        return False, None, error_msg


def get_vlm_model_from_workload(workload_config_path: str = None) -> tuple:
    """
    Extract vlm_model, vlm_precision, and vlm_device from workload configuration.

    Returns:
        (raw_vlm_model, vlm_precision, vlm_device)
    """
    # Resolve config path
    workload_dist = os.getenv("WORKLOAD_DIST")
    if workload_dist:
        workload_config_path = os.path.join(WORKLOAD_PIPELINE_CONFIG, workload_dist)

    if not workload_config_path:
        raise ValueError("WORKLOAD_DIST or workload_config_path must be provided")

    cfg_file = Path(workload_config_path)
    if not cfg_file.exists():
        raise FileNotFoundError(f"Workload config file not found: {cfg_file}")

    with open(cfg_file, "r") as f:
        config = json.load(f)

    workload_map = config.get("workload_pipeline_map", {})

    # 1️⃣ Select the lp_vlm workload
    pipeline_list = workload_map.get(TARGET_WORKLOAD)
    if not isinstance(pipeline_list, list):
        raise ValueError(f"No pipeline list found for workload '{TARGET_WORKLOAD}'")

    # 2️⃣ Find the VLM entry inside lp_vlm
    for entry in pipeline_list:
        if not isinstance(entry, dict):
            continue

        if entry.get("type", "").lower() == "vlm":
            vlm_model = entry.get("vlm_model")
            vlm_precision = entry.get("vlm_precision", "int8")
            vlm_device = entry.get("vlm_device", "GPU")

            if not vlm_model:
                raise ValueError("vlm_model is missing in VLM configuration")

            logger.info(
                "✅ Found VLM config: model=%s, precision=%s, device=%s",
                vlm_model,
                vlm_precision,
                vlm_device,
            )

            return vlm_model, vlm_precision, vlm_device

    raise ValueError(
        f"No VLM entry found in workload '{TARGET_WORKLOAD}'"
    )