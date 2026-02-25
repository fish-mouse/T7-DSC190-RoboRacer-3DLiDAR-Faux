#!/usr/bin/env python3
"""
Main test orchestrator — runs localization with real Livox MID-360 bag data
and monitors CPU/memory/temperature performance for RPi 5 benchmarking.

Plays the bag ONCE (no loop) and auto-stops when playback finishes.
Produces:
  /workspace/logs/cpu_log.csv          — per-second samples
  /workspace/logs/cpu_test_results.json — summary statistics
"""

import subprocess
import time
import signal
import sys
import os

BAG_DIR = "/workspace/rosbag2_2024_04_16-14_17_01"


def run_test(bag_rate=1.0):
    print("=" * 62)
    print("  3D LiDAR Localization CPU Benchmark")
    print("  Livox MID-360 | NDT Scan Matching | ROS2 Humble")
    print("=" * 62)
    print(f"  Bag data : {BAG_DIR}")
    print(f"  Rate     : {bag_rate}x  (no loop — single playback)")
    print(f"  Output   : /workspace/logs/cpu_log.csv")
    print("=" * 62)
    print()

    processes = []

    def cleanup(sig=None, frame=None):
        print("\nShutting down all processes...")
        for proc in processes:
            try:
                proc.terminate()
            except Exception:
                pass
        time.sleep(3)
        for proc in processes:
            try:
                if proc.poll() is None:
                    proc.kill()
            except Exception:
                pass

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    try:
        # Step 0: static TF publisher (base_link -> livox_frame)
        print("[0/3] Publishing static TF: base_link -> livox_frame")
        tf_proc = subprocess.Popen(
            ["ros2", "run", "tf2_ros", "static_transform_publisher",
             "0", "0", "0", "0", "0", "0", "base_link", "livox_frame"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        processes.append(tf_proc)
        time.sleep(2)

        # Step 1: localization node (use clean launch file from scripts/)
        launch_file = "/workspace/scripts/localization.launch.py"
        params_yaml = "/workspace/scripts/localization_params.yaml"
        print("[1/3] Launching localization (NDT scan matcher)...")
        loc_proc = subprocess.Popen(
            ["ros2", "launch", launch_file,
             f"mapping_param_dir:={params_yaml}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        processes.append(loc_proc)
        print("      Waiting 15 s for initialization...")
        time.sleep(15)

        # Step 2: CPU monitor (runs in background, writes CSV)
        print("[2/3] Starting CPU/memory monitor -> /workspace/logs/cpu_log.csv")
        monitor_proc = subprocess.Popen(
            ["python3", "/workspace/scripts/run_localization_test.py"]
        )
        processes.append(monitor_proc)
        time.sleep(2)

        # Step 3: play bag ONCE
        if not os.path.isdir(BAG_DIR):
            print(f"ERROR: Bag directory not found: {BAG_DIR}")
            cleanup()
            sys.exit(1)

        print(f"[3/3] Playing bag at {bag_rate}x (single pass, ~277 s)...")
        print("      Monitoring will run until playback finishes.\n")
        bag_proc = subprocess.Popen(
            ["ros2", "bag", "play", BAG_DIR,
             "--rate", str(bag_rate),
             "--disable-keyboard-controls"],
        )
        processes.append(bag_proc)

        # Wait for bag playback to finish
        bag_proc.wait()
        print("\nBag playback complete. Collecting final samples...")
        time.sleep(10)

        # Stop monitor gracefully (SIGINT triggers its shutdown/report)
        monitor_proc.send_signal(signal.SIGINT)
        monitor_proc.wait(timeout=15)

        cleanup()

    except Exception as e:
        print(f"Error: {e}")
        cleanup()
        sys.exit(1)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Run 3D LiDAR localization CPU benchmark (single bag pass)"
    )
    parser.add_argument(
        "--bag-rate", type=float, default=1.0,
        help="Bag playback speed (default: 1.0)",
    )
    args = parser.parse_args()
    run_test(bag_rate=args.bag_rate)
