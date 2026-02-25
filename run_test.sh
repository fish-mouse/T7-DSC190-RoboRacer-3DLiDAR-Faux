#!/bin/bash
# Run the complete localization CPU test with real Livox MID-360 bag data

echo "Starting 3D LiDAR localization CPU test..."
echo "Data: Livox MID-360 rosbag2 (native ROS2)"
echo ""

# Check for map file
if [ ! -f "./maps/map.pcd" ]; then
    echo "WARNING: No map.pcd found in ./maps/"
    echo "Please create a map first by running:"
    echo "  ./process_bag_to_map.sh"
    echo ""
    echo "This will use the Livox MID-360 bag data to build a 3D map."
    exit 1
fi

# Check for bag data
if [ ! -d "./rosbag2_2024_04_16-14_17_01" ]; then
    echo "WARNING: Bag data not found!"
    echo "Expected: ./rosbag2_2024_04_16-14_17_01/"
    echo ""
    echo "Download from: https://zenodo.org/records/14841855"
    echo "Unzip and place the folder in this directory."
    exit 1
fi

echo "Map file:  ./maps/map.pcd ($(ls -lh ./maps/map.pcd | awk '{print $5}'))"
echo "Bag data:  ./rosbag2_2024_04_16-14_17_01/"
echo ""

# Run test: 5 minutes with real bag data at 1x speed, looping
docker-compose run --rm localization \
    python3 /workspace/scripts/run_full_test.py \
    --duration 300 \
    --bag-rate 1.0

echo ""
echo "Test complete! Check logs/ directory for results:"
echo "  logs/cpu_test_results.json"
