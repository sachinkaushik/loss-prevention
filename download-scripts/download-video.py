#!/usr/bin/env python3
"""
Download and format videos for each camera in camera_to_workload.json by calling format_avc_mp4.sh.
"""
import json
import sys
import subprocess
from pathlib import Path
import argparse

def process_camera_videos(config_path, script_path):
    """Call format_avc_mp4.sh for each camera in the config, in sample-media dir."""
    config_path = Path(config_path)
    sample_media_dir = Path(__file__).parent.parent / "performance-tools" / "sample-media"
    sample_media_dir.mkdir(parents=True, exist_ok=True)
    script_path = str(Path(script_path).resolve())  # Always use absolute path
    if not config_path.exists():
        print(f"No camera configuration found at {config_path}, skipping video download.")
        return
    with open(config_path, "r") as f:
        config = json.load(f)
    # Support new format: top-level keys are lane names, each with a cameras array
    for lane_obj in config.values():
        cameras = lane_obj.get("cameras", [])
        for cam in cameras:
            file_src = cam.get("fileSrc", "")
            if "|" not in file_src:
                continue
            filename, url = [x.strip() for x in file_src.split("|", 1)]
            width = str(cam.get("width", ""))
            height = str(cam.get("height", ""))
            fps = str(cam.get("fps", ""))
            print(f"Processing: {filename} from {url}")
            # Only pass width/height/fps if all are valid, or only fps if valid, else nothing
            if width.isdigit() and height.isdigit() and fps.isdigit():
                cmd = [script_path, filename, url, width, height, fps]
            elif fps.isdigit():
                cmd = [script_path, filename, url, '', '', fps]
            else:
                cmd = [script_path, filename, url]
            try:
                subprocess.run(cmd, check=True, cwd=sample_media_dir)
            except subprocess.CalledProcessError as e:
                print(f"Error running {script_path} for {filename}: {e}")

def main():
    parser = argparse.ArgumentParser(description='Download and format videos for each camera in camera_to_workload.json')
    parser.add_argument('--camera-config', default='../configs/camera_to_workload.json', help='Path to camera_to_workload.json')
    parser.add_argument('--format-script', default='./format_avc_mp4.sh', help='Path to format_avc_mp4.sh script')
    args = parser.parse_args()
    process_camera_videos(args.camera_config, args.format_script)

if __name__ == '__main__':
    main()
