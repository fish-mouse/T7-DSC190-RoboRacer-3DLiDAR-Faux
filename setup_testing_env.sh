#!/bin/bash
# Complete setup script for localization testing environment

set -e

echo "=========================================="
echo "Setting up Localization Testing Environment"
echo "=========================================="

# Create directory structure
echo "[1/4] Creating directory structure..."
mkdir -p scripts maps data logs

# Create Dockerfile
echo "[2/4] Creating Dockerfile..."
cat > Dockerfile << 'EOF'
FROM ros:humble-ros-base

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=humble

# Install dependencies
RUN apt-get update && apt-get install -y \
    git \
    python3-pip \
    python3-dev \
    python3-numpy \
    python3-opencv \
    libeigen3-dev \
    libpcl-dev \
    libg2o \
    ros-${ROS_DISTRO}-pcl-ros \
    ros-${ROS_DISTRO}-pcl-conversions \
    htop \
    stress-ng \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir \
    psutil \
    numpy \
    open3d \
    matplotlib \
    pandas \
    pyyaml

WORKDIR /workspace
RUN mkdir -p /workspace/src

# Clone and build RoboRacer-3DLiDAR
RUN cd /workspace/src && \
    git clone https://github.com/TUM-AVS/RoboRacer-3DLiDAR.git

# Install Livox SDK
RUN cd /tmp && \
    git clone https://github.com/Livox-SDK/Livox-SDK2.git && \
    cd Livox-SDK2 && \
    mkdir build && cd build && \
    cmake .. && make -j$(nproc) && make install && \
    rm -rf /tmp/Livox-SDK2

# Build workspace
RUN cd /workspace && \
    . /opt/ros/${ROS_DISTRO}/setup.sh && \
    colcon build --packages-select lidarslam scanmatcher_custom --cmake-args -DCMAKE_BUILD_TYPE=Release

COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /workspace/maps /workspace/logs /workspace/test_data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
EOF

# Create docker-compose.yml
echo "[2/4] Creating docker-compose.yml..."
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  localization:
    build: .
    container_name: lidar_localization_test
    privileged: true
    network_mode: host
    volumes:
      - ./scripts:/workspace/scripts
      - ./maps:/workspace/maps
      - ./data:/workspace/test_data
      - ./logs:/workspace/logs
      - /sys/class/thermal:/sys/class/thermal:ro
    environment:
      - ROS_DOMAIN_ID=0
      - DISPLAY=${DISPLAY}
    devices:
      - /dev/dri:/dev/dri
    command: python3 /workspace/scripts/run_localization_test.py
EOF

# Create entrypoint.sh
echo "[3/4] Creating scripts..."
cat > scripts/entrypoint.sh << 'EOF'
#!/bin/bash
set -e

source /opt/ros/humble/setup.bash
source /workspace/install/setup.bash

exec "$@"
EOF

# Create run_localization_test.py
cat > scripts/run_localization_test.py << 'EOF'
#!/usr/bin/env python3
"""
Main script to run 3D LiDAR localization and monitor CPU performance on RPi 5
"""

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import PointCloud2
from geometry_msgs.msg import PoseStamped
from nav_msgs.msg import Path
import psutil
import time
import json
import threading
from datetime import datetime
import numpy as np

class LocalizationCPUMonitor(Node):
    def __init__(self):
        super().__init__('localization_cpu_monitor')
        
        self.pose_sub = self.create_subscription(
            PoseStamped,
            '/current_pose',
            self.pose_callback,
            10
        )
        
        self.map_sub = self.create_subscription(
            PointCloud2,
            '/map',
            self.map_callback,
            10
        )
        
        self.metrics = {
            'cpu_percent': [],
            'cpu_per_core': [],
            'memory_percent': [],
            'memory_mb': [],
            'temperature': [],
            'pose_updates': [],
            'timestamps': []
        }
        
        self.pose_count = 0
        self.map_received = False
        self.start_time = time.time()
        
        self.monitoring = True
        self.monitor_thread = threading.Thread(target=self.monitor_system)
        self.monitor_thread.daemon = True
        self.monitor_thread.start()
        
        self.create_timer(1.0, self.report_metrics)
        
        self.get_logger().info('Localization CPU Monitor started')
    
    def pose_callback(self, msg):
        self.pose_count += 1
        self.get_logger().info(
            f'Pose update {self.pose_count}: '
            f'[{msg.pose.position.x:.2f}, {msg.pose.position.y:.2f}, {msg.pose.position.z:.2f}]'
        )
    
    def map_callback(self, msg):
        if not self.map_received:
            self.map_received = True
            self.get_logger().info(f'Map received: {msg.width * msg.height} points')
    
    def get_cpu_temperature(self):
        try:
            with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
                temp = float(f.read().strip()) / 1000.0
                return temp
        except:
            return None
    
    def monitor_system(self):
        while self.monitoring:
            timestamp = time.time() - self.start_time
            
            cpu_percent = psutil.cpu_percent(interval=0.1)
            cpu_per_core = psutil.cpu_percent(interval=0.1, percpu=True)
            
            mem = psutil.virtual_memory()
            temp = self.get_cpu_temperature()
            
            self.metrics['timestamps'].append(timestamp)
            self.metrics['cpu_percent'].append(cpu_percent)
            self.metrics['cpu_per_core'].append(cpu_per_core)
            self.metrics['memory_percent'].append(mem.percent)
            self.metrics['memory_mb'].append(mem.used / (1024 * 1024))
            self.metrics['temperature'].append(temp)
            self.metrics['pose_updates'].append(self.pose_count)
            
            time.sleep(0.5)
    
    def report_metrics(self):
        if len(self.metrics['timestamps']) == 0:
            return
        
        elapsed = time.time() - self.start_time
        recent_cpu = self.metrics['cpu_percent'][-10:] if len(self.metrics['cpu_percent']) >= 10 else self.metrics['cpu_percent']
        recent_temp = [t for t in self.metrics['temperature'][-10:] if t is not None]
        
        avg_cpu = np.mean(recent_cpu) if recent_cpu else 0
        avg_temp = np.mean(recent_temp) if recent_temp else 0
        
        self.get_logger().info(
            f'--- Performance Report (t={elapsed:.1f}s) ---\n'
            f'  CPU Usage: {avg_cpu:.1f}% (avg last 5s)\n'
            f'  Temperature: {avg_temp:.1f}°C\n'
            f'  Memory: {self.metrics["memory_percent"][-1]:.1f}%\n'
            f'  Pose Updates: {self.pose_count}\n'
            f'  Map Loaded: {self.map_received}'
        )
    
    def save_results(self, filename='/workspace/logs/cpu_test_results.json'):
        results = {
            'test_duration': time.time() - self.start_time,
            'pose_updates_total': self.pose_count,
            'cpu_avg': float(np.mean(self.metrics['cpu_percent'])) if self.metrics['cpu_percent'] else 0,
            'cpu_max': float(np.max(self.metrics['cpu_percent'])) if self.metrics['cpu_percent'] else 0,
            'cpu_min': float(np.min(self.metrics['cpu_percent'])) if self.metrics['cpu_percent'] else 0,
            'memory_avg_mb': float(np.mean(self.metrics['memory_mb'])) if self.metrics['memory_mb'] else 0,
            'memory_max_mb': float(np.max(self.metrics['memory_mb'])) if self.metrics['memory_mb'] else 0,
            'temperature_avg': float(np.mean([t for t in self.metrics['temperature'] if t is not None])) if any(t is not None for t in self.metrics['temperature']) else 0,
            'temperature_max': float(np.max([t for t in self.metrics['temperature'] if t is not None])) if any(t is not None for t in self.metrics['temperature']) else 0,
            'raw_metrics': {
                'timestamps': [float(t) for t in self.metrics['timestamps']],
                'cpu_percent': [float(c) for c in self.metrics['cpu_percent']],
                'memory_mb': [float(m) for m in self.metrics['memory_mb']],
                'temperature': [float(t) if t is not None else None for t in self.metrics['temperature']],
            }
        }
        
        with open(filename, 'w') as f:
            json.dump(results, f, indent=2)
        
        self.get_logger().info(f'Results saved to {filename}')
        return results
    
    def shutdown(self):
        self.monitoring = False
        self.monitor_thread.join()
        results = self.save_results()
        
        print("\n" + "="*60)
        print("FINAL TEST RESULTS")
        print("="*60)
        print(f"Test Duration: {results['test_duration']:.1f} seconds")
        print(f"Total Pose Updates: {results['pose_updates_total']}")
        print(f"CPU Usage - Avg: {results['cpu_avg']:.1f}%, Max: {results['cpu_max']:.1f}%")
        print(f"Memory Usage - Avg: {results['memory_avg_mb']:.0f} MB, Max: {results['memory_max_mb']:.0f} MB")
        print(f"Temperature - Avg: {results['temperature_avg']:.1f}°C, Max: {results['temperature_max']:.1f}°C")
        print("="*60)

def main():
    rclpy.init()
    monitor = LocalizationCPUMonitor()
    
    try:
        rclpy.spin(monitor)
    except KeyboardInterrupt:
        print("\nShutting down gracefully...")
    finally:
        monitor.shutdown()
        monitor.destroy_node()
        rclpy.shutdown()

if __name__ == '__main__':
    main()
EOF

# Create launch_localization.py
cat > scripts/launch_localization.py << 'EOF'
#!/usr/bin/env python3
import subprocess
import signal
import sys
import time
import os

class LocalizationLauncher:
    def __init__(self):
        self.processes = []
    
    def launch_localization(self, map_path='/workspace/maps/map.pcd'):
        if not os.path.exists(map_path):
            print(f"ERROR: Map file not found at {map_path}")
            sys.exit(1)
        
        print(f"Launching localization with map: {map_path}")
        
        cmd = ['ros2', 'launch', 'scanmatcher_custom', 'mapping_robot.launch.py']
        proc = subprocess.Popen(cmd)
        self.processes.append(proc)
        
        print("Localization node launched. PID:", proc.pid)
        return proc
    
    def signal_handler(self, sig, frame):
        print("\nShutting down all processes...")
        for proc in self.processes:
            proc.terminate()
        time.sleep(2)
        for proc in self.processes:
            if proc.poll() is None:
                proc.kill()
        sys.exit(0)
    
    def run(self):
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        self.launch_localization()
        
        try:
            while True:
                time.sleep(1)
                for proc in self.processes:
                    if proc.poll() is not None:
                        print(f"Process {proc.pid} terminated")
                        self.processes.remove(proc)
                
                if not self.processes:
                    print("All processes terminated")
                    break
        except KeyboardInterrupt:
            self.signal_handler(None, None)

if __name__ == '__main__':
    launcher = LocalizationLauncher()
    launcher.run()
EOF

# Create play_pointcloud_data.py
cat > scripts/play_pointcloud_data.py << 'EOF'
#!/usr/bin/env python3
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import PointCloud2, PointField
import numpy as np
import struct

class PointCloudPlayer(Node):
    def __init__(self):
        super().__init__('pointcloud_player')
        
        self.publisher = self.create_publisher(PointCloud2, '/livox/lidar', 10)
        self.timer = self.create_timer(0.1, self.publish_pointcloud)
        
        self.frame_id = 'livox_frame'
        self.get_logger().info('PointCloud Player started')
    
    def generate_sample_pointcloud(self):
        points = []
        
        # Floor
        for x in np.linspace(-5, 5, 50):
            for y in np.linspace(-5, 5, 50):
                points.append([x, y, 0.0, 50.0])
        
        # Walls
        for x in np.linspace(-5, 5, 50):
            for z in np.linspace(0, 3, 30):
                points.append([x, -5.0, z, 100.0])
                points.append([x, 5.0, z, 100.0])
        
        for y in np.linspace(-5, 5, 50):
            for z in np.linspace(0, 3, 30):
                points.append([-5.0, y, z, 100.0])
                points.append([5.0, y, z, 100.0])
        
        return np.array(points, dtype=np.float32)
    
    def create_pointcloud2_msg(self, points):
        msg = PointCloud2()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = self.frame_id
        
        msg.height = 1
        msg.width = len(points)
        
        msg.fields = [
            PointField(name='x', offset=0, datatype=PointField.FLOAT32, count=1),
            PointField(name='y', offset=4, datatype=PointField.FLOAT32, count=1),
            PointField(name='z', offset=8, datatype=PointField.FLOAT32, count=1),
            PointField(name='intensity', offset=12, datatype=PointField.FLOAT32, count=1),
        ]
        
        msg.is_bigendian = False
        msg.point_step = 16
        msg.row_step = msg.point_step * msg.width
        msg.is_dense = True
        
        buffer = []
        for point in points:
            buffer.append(struct.pack('ffff', point[0], point[1], point[2], point[3]))
        
        msg.data = b''.join(buffer)
        return msg
    
    def publish_pointcloud(self):
        points = self.generate_sample_pointcloud()
        msg = self.create_pointcloud2_msg(points)
        self.publisher.publish(msg)
        self.get_logger().info(f'Published {len(points)} points')

def main():
    rclpy.init()
    player = PointCloudPlayer()
    
    try:
        rclpy.spin(player)
    except KeyboardInterrupt:
        pass
    finally:
        player.destroy_node()
        rclpy.shutdown()

if __name__ == '__main__':
    main()
EOF

# Create run_full_test.py
cat > scripts/run_full_test.py << 'EOF'
#!/usr/bin/env python3
import subprocess
import time
import signal
import sys

def run_test(duration=60):
    print("="*60)
    print("3D LiDAR Localization CPU Test for Raspberry Pi 5")
    print("="*60)
    print(f"Test duration: {duration} seconds\n")
    
    processes = []
    
    def cleanup(sig, frame):
        print("\nCleaning up...")
        for proc in processes:
            proc.terminate()
        time.sleep(2)
        for proc in processes:
            proc.kill()
        sys.exit(0)
    
    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)
    
    try:
        print("[1/3] Launching localization node...")
        loc_proc = subprocess.Popen([
            'ros2', 'launch', 'scanmatcher_custom', 'mapping_robot.launch.py'
        ])
        processes.append(loc_proc)
        time.sleep(5)
        
        print("[2/3] Launching point cloud player...")
        player_proc = subprocess.Popen([
            'python3', '/workspace/scripts/play_pointcloud_data.py'
        ])
        processes.append(player_proc)
        time.sleep(2)
        
        print("[3/3] Launching CPU monitor...")
        monitor_proc = subprocess.Popen([
            'python3', '/workspace/scripts/run_localization_test.py'
        ])
        processes.append(monitor_proc)
        
        print(f"\nTest running for {duration} seconds...")
        print("Press Ctrl+C to stop early\n")
        
        time.sleep(duration)
        
        print("\nTest complete! Shutting down...")
        cleanup(None, None)
    
    except Exception as e:
        print(f"Error: {e}")
        cleanup(None, None)

if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser()
    parser.add_argument('--duration', type=int, default=60)
    args = parser.parse_args()
    
    run_test(duration=args.duration)
EOF

# Create build.sh
cat > build.sh << 'EOF'
#!/bin/bash
echo "Building Docker container for RPi 5..."
docker-compose build
echo "Build complete!"
EOF

# Create run_test.sh
cat > run_test.sh << 'EOF'
#!/bin/bash
echo "Starting localization CPU test..."

if [ ! -f "./maps/map.pcd" ]; then
    echo "WARNING: No map.pcd found in ./maps/"
    echo "Download from: https://zenodo.org/records/14841855"
    exit 1
fi

docker-compose run --rm localization python3 /workspace/scripts/run_full_test.py --duration 120

echo "Test complete! Check logs/ directory"
EOF

# Create README_TESTING.md
cat > README_TESTING.md << 'EOF'
# Localization CPU Testing on Raspberry Pi 5

## Quick Start

### 1. Setup
```bash
chmod +x build.sh run_test.sh scripts/*.sh
./build.sh