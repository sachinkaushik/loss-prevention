#!/bin/bash
#
# Copyright (C) 2025 Intel Corporation.
#
# SPDX-License-Identifier: Apache-2.0
#


echo "############# Generating GStreamer pipeline commands for all lanes ##########"
echo "################### RENDER_MODE #################"$RENDER_MODE 

# Get JSON output from Python script
lane_json=$(python3 "$(dirname "$0")/gst-pipeline-generator.py")
echo "#############  GStreamer pipeline commands generated successfully ##########"

timestamp=$(date +"%Y%m%d_%H%M%S")
pipelines_dir="/home/pipeline-server/pipelines"
mkdir -p "$pipelines_dir"

if [ -d "$pipelines_dir" ]; then
    echo "################# Pipelines directory exists: $pipelines_dir ###################"
else
    echo "################# ERROR: Failed to create pipelines directory: $pipelines_dir ###################"
fi

# Parse lane_json and create per-lane pipeline shell scripts
# Requires 'jq' for JSON parsing
if ! command -v jq &> /dev/null; then
    echo "################# ERROR: 'jq' is required but not installed. Please install jq. ###################"
    exit 1
fi

lane_names=$(echo "$lane_json" | jq -r 'keys[]')
for lane in $lane_names; do
    lane_file="$pipelines_dir/pipeline_${lane}.sh"
    echo "################# Creating pipeline file for lane: $lane -> $lane_file ###################"
    echo "#!/bin/bash" > "$lane_file"
    echo "# Generated GStreamer pipeline command for lane: $lane" >> "$lane_file"
    echo "# Generated on: $(date)" >> "$lane_file"
    echo "" >> "$lane_file"
    gst_cmd=$(echo "$lane_json" | jq -r --arg lane "$lane" '.[$lane]')
    # Write the gst_cmd and logging on the same line for correct execution
    echo "$gst_cmd 2>&1 | tee /home/pipeline-server/results/pipeline_${lane}_${timestamp}.log | (stdbuf -oL sed -n -E 's/.*total=([0-9]+\\.[0-9]+) fps.*/\\1/p' > /home/pipeline-server/results/fps_${lane}_${timestamp}.log)" >> "$lane_file"
    chmod +x "$lane_file"
    if [ -f "$lane_file" ]; then
        echo "################# Pipeline file created successfully: $lane_file ###################"
        echo "################# File size: $(stat -c%s "$lane_file") bytes ###################"
    else
        echo "################# ERROR: Failed to create pipeline file: $lane_file ###################"
    fi
    echo "################# Running Pipeline for lane: $lane ###################"
    echo "$gst_cmd"
    bash "$lane_file" &
done

wait
echo "############# ALL GST PIPELINES COMPLETED SUCCESSFULLY #############"

sleep 10m