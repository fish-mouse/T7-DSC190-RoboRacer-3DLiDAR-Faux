#!/bin/bash
# Convert bag file to .pcd map - fully containerized

set -e

BAG_FILE="hdl_501_filtered.bag"

echo "=========================================="
echo "Creating Map from Bag File (Containerized)"
echo "=========================================="
echo "Bag file: $BAG_FILE"
echo ""

# Check if bag file exists on host
if [ ! -f "$BAG_FILE" ]; then
    echo "❌ Error: Bag file not found: $BAG_FILE"
    echo "Expected location: $(pwd)/$BAG_FILE"
    echo ""
    echo "Make sure you've extracted it:"
    echo "  tar -xzf hdl_501_filtered.bag.tar.gz"
    exit 1
fi

# Start container
echo "[1/6] Starting Docker container..."
docker-compose up -d
sleep 3

# Copy bag file into container
echo "[2/6] Copying bag file to container..."
docker cp "$BAG_FILE" lidar_localization_test:/workspace/
echo "✅ Bag file copied"

# Check bag info inside container (no host installation needed!)
echo ""
echo "[3/6] Inspecting bag file (inside container)..."
docker exec lidar_localization_test bash -c "
    # Install rosbag tools inside container
    apt-get update -qq
    apt-get install -y -qq python3-rosbag ros-humble-rosbag2-bag-v2 > /dev/null 2>&1
    
    echo '─────────────────────────────────────────'
    echo 'Bag file information:'
    echo '─────────────────────────────────────────'
    rosbag info /workspace/$BAG_FILE | head -20
    echo '─────────────────────────────────────────'
"

echo ""
read -p "Does the bag have a point cloud topic? Check above for topics like /velodyne_points or /points_raw. Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

# Run the mapping process
echo ""
echo "[4/6] Running SLAM mapping (this takes 3-5 minutes)..."
echo "Processing bag file and creating map..."
docker exec lidar_localization_test bash -c "
    set -e
    
    source /opt/ros/humble/setup.bash
    source /workspace/install/setup.bash
    
    echo 'Starting SLAM node...'
    ros2 launch lidarslam lidarslam.launch.py > /tmp/slam.log 2>&1 &
    SLAM_PID=\$!
    
    echo 'Waiting for initialization (10 seconds)...'
    sleep 10
    
    echo 'Playing bag file at 2x speed...'
    ros2 bag play -s rosbag_v2 /workspace/$BAG_FILE --rate 2.0 2>&1 | head -10
    
    echo 'Bag playback complete. Waiting for processing...'
    sleep 5
    
    echo 'Saving map...'
    ros2 service call /map_save std_srvs/Empty
    
    sleep 3
    
    echo 'Stopping SLAM node...'
    kill \$SLAM_PID 2>/dev/null || true
    
    echo 'Checking if map was created...'
    find /workspace -name 'map.pcd' -ls
"

# Find and copy the map back to host
echo ""
echo "[5/6] Copying map to host..."
docker exec lidar_localization_test bash -c "
    # Find the map file
    MAP_FILE=\$(find /workspace -name 'map.pcd' -type f | head -1)
    
    if [ -n \"\$MAP_FILE\" ]; then
        echo \"Found map at: \$MAP_FILE\"
        cp \"\$MAP_FILE\" /workspace/maps/map.pcd
        ls -lh /workspace/maps/map.pcd
    else
        echo '❌ Error: map.pcd not found'
        exit 1
    fi
"

docker cp lidar_localization_test:/workspace/maps/map.pcd ./maps/

# Verify
echo ""
echo "[6/6] Verifying..."
if [ -f "./maps/map.pcd" ]; then
    echo ""
    echo "=========================================="
    echo "✅ SUCCESS!"
    echo "=========================================="
    echo "Map created at: ./maps/map.pcd"
    ls -lh ./maps/map.pcd
    echo ""
    echo "Next step: Run the test"
    echo "  ./run_test.sh"
    echo "=========================================="
else
    echo ""
    echo "=========================================="
    echo "❌ ERROR"
    echo "=========================================="
    echo "Map file was not created successfully"
    echo ""
    echo "Debug information:"
    echo "1. Check SLAM logs:"
    echo "   docker exec lidar_localization_test cat /tmp/slam.log"
    echo ""
    echo "2. Check if bag played correctly:"
    echo "   docker exec lidar_localization_test ls -lh /workspace/*.bag"
    echo ""
    echo "3. Search for any .pcd files:"
    echo "   docker exec lidar_localization_test find /workspace -name '*.pcd'"
    echo "=========================================="
    exit 1
fi

echo ""
echo "Cleaning up..."
# Optional: stop container
# docker-compose down

echo "Done!"