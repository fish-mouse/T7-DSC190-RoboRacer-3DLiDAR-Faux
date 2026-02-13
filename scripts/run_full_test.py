#!/usr/bin/env python3
"""
Main test orchestrator - runs complete localization test with monitoring
"""

import subprocess
import time
import signal
import sys
import os

def run_test(duration=60):
    """
    Run complete localization test
    
    Args:
        duration: Test duration in seconds
    """
    
    print("="*60)
    print("3D LiDAR Localization CPU Test for Raspberry Pi 5")
    print("="*60)
    print(f"Test duration: {duration} seconds")
    print()
    
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
        # Step 1: Launch localization node
        print("[1/3] Launching localization node...")
        loc_proc = subprocess.Popen([
            'ros2', 'launch', 'scanmatcher_custom', 'mapping_robot.launch.py'
        ])
        processes.append(loc_proc)
        time.sleep(5)
        
        # Step 2: Launch point cloud player (simulates LiDAR)
        print("[2/3] Launching point cloud player...")
        player_proc = subprocess.Popen([
            'python3', '/workspace/scripts/play_pointcloud_data.py'
        ])
        processes.append(player_proc)
        time.sleep(2)
        
        # Step 3: Launch CPU monitor
        print("[3/3] Launching CPU monitor...")
        monitor_proc = subprocess.Popen([
            'python3', '/workspace/scripts/run_localization_test.py'
        ])
        processes.append(monitor_proc)
        
        print(f"\nTest running for {duration} seconds...")
        print("Press Ctrl+C to stop early\n")
        
        # Wait for test duration
        time.sleep(duration)
        
        print("\nTest complete! Shutting down...")
        cleanup(None, None)
    
    except Exception as e:
        print(f"Error during test: {e}")
        cleanup(None, None)

if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='Run localization CPU test')
    parser.add_argument('--duration', type=int, default=60, help='Test duration in seconds')
    args = parser.parse_args()
    
    run_test(duration=args.duration)