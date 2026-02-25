#!/bin/bash
# Convert ROS2 bag file to .pcd map - fully containerized
# Uses Livox MID-360 rosbag2 data (native ROS2 format)

set -e

BAG_DIR="rosbag2_2024_04_16-14_17_01"
CONTAINER_BAG_DIR="/workspace/$BAG_DIR"

echo "=========================================="
echo "Creating Map from Bag File (Containerized)"
echo "=========================================="
echo "Bag directory: $BAG_DIR"
echo ""

# Check if bag directory exists on host
if [ ! -d "$BAG_DIR" ]; then
    echo "Error: Bag directory not found: $BAG_DIR"
    echo "Expected location: $(pwd)/$BAG_DIR"
    echo ""
    echo "Make sure you have the rosbag2 folder containing:"
    echo "  $BAG_DIR/metadata.yaml"
    echo "  $BAG_DIR/*.db3"
    echo ""
    echo "Download from: https://zenodo.org/records/14841855"
    exit 1
fi

# Verify bag contents
if [ ! -f "$BAG_DIR/metadata.yaml" ]; then
    echo "Error: metadata.yaml not found in $BAG_DIR/"
    exit 1
fi

DB3_COUNT=$(find "$BAG_DIR" -name "*.db3" | wc -l | tr -d ' ')
if [ "$DB3_COUNT" -eq 0 ]; then
    echo "Error: No .db3 files found in $BAG_DIR/"
    exit 1
fi

echo "Found $DB3_COUNT .db3 file(s) in bag directory"

# Start container (bag dir is mounted via docker-compose volume)
echo ""
echo "[1/5] Starting Docker container..."
docker-compose up -d
sleep 3

# Verify bag is accessible inside container
echo ""
echo "[2/5] Inspecting bag file (inside container)..."
docker exec lidar_localization_test bash -c "
    source /opt/ros/humble/setup.bash

    echo '-----------------------------------------------'
    echo 'Bag file information:'
    echo '-----------------------------------------------'
    ros2 bag info $CONTAINER_BAG_DIR
    echo '-----------------------------------------------'
"

echo ""
echo "Expected topics: /livox/lidar (PointCloud2) and /livox/imu (Imu)"
read -p "Does the bag have the expected point cloud topic? Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

# Run the mapping process
echo ""
echo "[3/5] Running SLAM mapping (this may take 5-10 minutes)..."
echo "Processing bag file and creating map..."
docker exec lidar_localization_test bash -c "
    set -e

    source /opt/ros/humble/setup.bash
    source /workspace/install/setup.bash

    # Publish the base_link -> livox_frame static TF (identity)
    # The launch file in the cloned repo has this commented out, so we run it manually.
    echo 'Starting static_transform_publisher (base_link -> livox_frame)...'
    ros2 run tf2_ros static_transform_publisher 0 0 0 0 0 0 base_link livox_frame > /tmp/tf.log 2>&1 &
    TF_PID=\$!
    sleep 2

    echo 'Starting SLAM node...'
    ros2 launch lidarslam lidarslam.launch.py > /tmp/slam.log 2>&1 &
    SLAM_PID=\$!

    echo 'Waiting for SLAM initialization (15 seconds)...'
    sleep 15

    # Verify TF is available before playing bag
    echo 'Verifying TF tree...'
    ros2 run tf2_ros tf2_echo base_link livox_frame --wait-for-server 2>&1 | head -5 &
    sleep 3

    echo 'Playing Livox MID-360 bag at 1x speed...'
    echo '  Topics: /livox/lidar (PointCloud2), /livox/imu (Imu)'
    echo '  Duration: ~277 seconds. Please wait...'
    ros2 bag play $CONTAINER_BAG_DIR --rate 1.0 --disable-keyboard-controls

    echo 'Bag playback complete. Waiting for SLAM to finish processing...'
    sleep 20

    echo 'Saving map...'
    ros2 service call /map_save std_srvs/Empty

    sleep 5

    echo 'Stopping SLAM node...'
    kill \$SLAM_PID 2>/dev/null || true
    kill \$TF_PID 2>/dev/null || true

    echo 'Checking if map was created...'
    find /workspace -name 'map.pcd' -ls

    echo ''
    echo 'SLAM log (last 20 lines):'
    tail -20 /tmp/slam.log
"

# Copy map to the mounted maps directory
echo ""
echo "[4/5] Copying map to output..."
docker exec lidar_localization_test bash -c "
    MAP_FILE=\$(find /workspace -name 'map.pcd' -type f -not -path '/workspace/maps/*' | head -1)

    if [ -n \"\$MAP_FILE\" ]; then
        echo \"Found map at: \$MAP_FILE\"
        cp \"\$MAP_FILE\" /workspace/maps/map.pcd
        ls -lh /workspace/maps/map.pcd
    else
        # Check if it was saved directly to maps
        if [ -f /workspace/maps/map.pcd ]; then
            echo 'Map already in /workspace/maps/map.pcd'
            ls -lh /workspace/maps/map.pcd
        else
            echo 'Error: map.pcd not found'
            exit 1
        fi
    fi
"

# Verify on host
echo ""
echo "[5/5] Verifying..."
if [ -f "./maps/map.pcd" ]; then
    echo ""
    echo "=========================================="
    echo "SUCCESS!"
    echo "=========================================="
    echo "Map created at: ./maps/map.pcd"
    ls -lh ./maps/map.pcd
    echo ""
    echo "Next step: Run the CPU test"
    echo "  ./run_test.sh"
    echo "=========================================="
else
    echo ""
    echo "=========================================="
    echo "ERROR"
    echo "=========================================="
    echo "Map file was not created successfully"
    echo ""
    echo "Debug information:"
    echo "1. Check SLAM logs:"
    echo "   docker exec lidar_localization_test cat /tmp/slam.log"
    echo ""
    echo "2. Check if bag exists in container:"
    echo "   docker exec lidar_localization_test ros2 bag info $CONTAINER_BAG_DIR"
    echo ""
    echo "3. Search for any .pcd files:"
    echo "   docker exec lidar_localization_test find /workspace -name '*.pcd'"
    echo "=========================================="
    exit 1
fi

echo ""
echo "Done!"
