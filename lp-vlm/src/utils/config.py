"""Configuration settings for the grocery video app."""

import os
import logging
from datetime import datetime

# ---------------- Base Configuration -----------------
LP_IP = os.environ.get("LP_IP")
LP_PORT = os.environ.get("LP_PORT", "8000")
MINIO_API_HOST_PORT = os.environ.get("MINIO_API_HOST_PORT", "4000")

VLM_MODEL = os.environ.get("VLM_MODEL_NAME", "Qwen/Qwen2.5-VL-7B-Instruct")
OVMS_ENDPOINT = os.environ.get("OVMS_ENDPOINT", "http://ovms-vlm:8000")
OVMS_MODEL_NAME = os.environ.get("OVMS_MODEL_NAME", VLM_MODEL)
SAMPLE_MEDIA_DIR = "sample-media"
LP_APP_BASE_DIR = "/app"

RESULTS_DIR = "results"
MODELS_DIR = "models"
LOGS_DIR = os.path.join(LP_APP_BASE_DIR)

MINIO_HOST = f"{LP_IP}:{MINIO_API_HOST_PORT}"

CONFIG_FILES_PATH = os.path.join(LP_APP_BASE_DIR, "config")
INVENTORY_FILE = os.path.join(CONFIG_FILES_PATH, "inventory.json")

# Generate timestamp for results file
TIMESTAMP = datetime.now().strftime("%Y%m%d%H%M%S")

AGENT_RESULTS_DIR_FULL_PATH = os.path.join(LP_APP_BASE_DIR, RESULTS_DIR, "agent_results.json")
COMMON_RESULTS_DIR_FULL_PATH = os.path.join(LP_APP_BASE_DIR, RESULTS_DIR,  f"results_{TIMESTAMP}.jsonl")
STREAM_RESULTS_DIR_FULL_PATH = os.path.join(LP_APP_BASE_DIR, RESULTS_DIR, "stream_results.log")

####### volume-mount paths ############
FRAME_DIR_VOL_BASE = "/app"
FRAME_DIR = "frames"


METADATA_DIR_FULL_PATH = os.path.join(FRAME_DIR_VOL_BASE, RESULTS_DIR)
FRAMES_DIR_FULL_PATH = os.path.join(FRAME_DIR_VOL_BASE, RESULTS_DIR, FRAME_DIR)

BUCKET_NAME = "loss-prevention-enhanced-vlm-results"

def setup_logging():
    logger = logging.getLogger("loss_prevention_app")
    logger.setLevel(logging.INFO)

    # Ensure logs directory exists
    os.makedirs(LOGS_DIR, exist_ok=True)
    
    file_handler = logging.FileHandler(os.path.join(LOGS_DIR, "loss_prevention_app.log"))
    formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
    file_handler.setFormatter(formatter)

    # Avoid duplicate handlers if called multiple times
    if not logger.handlers:
        logger.addHandler(file_handler)

    return logger


# Create logger instance
logger = setup_logging()



