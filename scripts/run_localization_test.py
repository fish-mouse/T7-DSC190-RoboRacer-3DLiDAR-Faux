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
        
        # Subscribers
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
        
        # Data storage
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
        
        # Start monitoring thread
        self.monitoring = True
        self.monitor_thread = threading.Thread(target=self.monitor_system)
        self.monitor_thread.daemon = True
        self.monitor_thread.start()
        
        # Timer for periodic reporting
        self.create_timer(1.0, self.report_metrics)
        
        self.get_logger().info('Localization CPU Monitor started')
    
    def pose_callback(self, msg):
        """Track pose updates"""
        self.pose_count += 1
        current_time = time.time() - self.start_time
        
        self.get_logger().info(
            f'Pose update {self.pose_count}: '
            f'[{msg.pose.position.x:.2f}, {msg.pose.position.y:.2f}, {msg.pose.position.z:.2f}]'
        )
    
    def map_callback(self, msg):
        """Track map reception"""
        if not self.map_received:
            self.map_received = True
            self.get_logger().info(f'Map received: {msg.width * msg.height} points')
    
    def get_cpu_temperature(self):
        """Get CPU temperature (RPi specific)"""
        try:
            with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
                temp = float(f.read().strip()) / 1000.0
                return temp
        except:
            return None
    
    def monitor_system(self):
        """Continuously monitor system resources"""
        while self.monitoring:
            timestamp = time.time() - self.start_time
            
            # CPU metrics
            cpu_percent = psutil.cpu_percent(interval=0.1)
            cpu_per_core = psutil.cpu_percent(interval=0.1, percpu=True)
            
            # Memory metrics
            mem = psutil.virtual_memory()
            
            # Temperature
            temp = self.get_cpu_temperature()
            
            # Store metrics
            self.metrics['timestamps'].append(timestamp)
            self.metrics['cpu_percent'].append(cpu_percent)
            self.metrics['cpu_per_core'].append(cpu_per_core)
            self.metrics['memory_percent'].append(mem.percent)
            self.metrics['memory_mb'].append(mem.used / (1024 * 1024))
            self.metrics['temperature'].append(temp)
            self.metrics['pose_updates'].append(self.pose_count)
            
            time.sleep(0.5)
    
    def report_metrics(self):
        """Periodic metrics reporting"""
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
        """Save all metrics to file"""
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
        """Clean shutdown"""
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