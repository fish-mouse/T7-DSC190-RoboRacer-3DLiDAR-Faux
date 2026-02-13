#!/bin/bash
# Run the complete test

echo "Starting localization CPU test..."

# Make sure maps directory has a map file
if [ ! -f "./maps/map.pcd" ]; then
    echo "WARNING: No map.pcd found in ./maps/"
    echo "Please place a .pcd map file in the maps directory"
    echo "You can download sample maps from:"
    echo "https://syncandshare.lrz.de/getlink/fiCk878yuz8FvFnavZWunU/Livox_LiDAR"
    exit 1
fi

# Run test
docker-compose run --rm localization python3 /workspace/scripts/run_full_test.py --duration 120

echo "Test complete! Check logs/ directory for results"