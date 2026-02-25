#!/usr/bin/env python3
"""
CPU/memory/temperature monitor for 3D LiDAR localization on RPi 5.
Writes per-second samples to CSV and prints a summary at the end.
"""

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import PointCloud2
from geometry_msgs.msg import PoseStamped
import psutil
import time
import csv
import json
import threading
import os
from datetime import datetime

CSV_PATH = "/workspace/logs/cpu_log.csv"
JSON_PATH = "/workspace/logs/cpu_test_results.json"

SAMPLE_INTERVAL = 1.0  # seconds between samples


class LocalizationCPUMonitor(Node):
    def __init__(self):
        super().__init__("localization_cpu_monitor")

        self.pose_sub = self.create_subscription(
            PoseStamped, "/current_pose", self.pose_callback, 10
        )
        self.map_sub = self.create_subscription(
            PointCloud2, "/map", self.map_callback, 10
        )

        self.pose_count = 0
        self.map_received = False
        self.start_time = time.time()

        self.rows = []

        os.makedirs(os.path.dirname(CSV_PATH), exist_ok=True)
        self.csv_file = open(CSV_PATH, "w", newline="")
        num_cores = psutil.cpu_count()
        core_headers = [f"core{i}_pct" for i in range(num_cores)]
        self.csv_writer = csv.writer(self.csv_file)
        self.csv_writer.writerow(
            ["elapsed_s", "total_cpu_pct"] + core_headers +
            ["mem_used_mb", "mem_pct", "temp_c", "pose_count"]
        )
        self.csv_file.flush()
        self.num_cores = num_cores

        # Warm up psutil so the first real reading isn't zero
        psutil.cpu_percent(interval=0.1)
        psutil.cpu_percent(interval=0.1, percpu=True)

        self.monitoring = True
        self.monitor_thread = threading.Thread(target=self._sample_loop, daemon=True)
        self.monitor_thread.start()

        self.create_timer(5.0, self._print_status)
        self.get_logger().info(
            f"Monitor started – logging to {CSV_PATH} every {SAMPLE_INTERVAL}s"
        )

    # ---- ROS callbacks ----
    def pose_callback(self, msg):
        self.pose_count += 1

    def map_callback(self, msg):
        if not self.map_received:
            self.map_received = True
            self.get_logger().info(f"Map received: {msg.width * msg.height} points")

    # ---- Sampling ----
    def _read_temp(self):
        try:
            with open("/sys/class/thermal/thermal_zone0/temp") as f:
                return float(f.read().strip()) / 1000.0
        except Exception:
            return None

    def _sample_loop(self):
        while self.monitoring:
            elapsed = time.time() - self.start_time
            total = psutil.cpu_percent(interval=0.2)
            per_core = psutil.cpu_percent(interval=0.2, percpu=True)
            mem = psutil.virtual_memory()
            temp = self._read_temp()

            row = {
                "elapsed_s": round(elapsed, 1),
                "total_cpu_pct": total,
                "per_core": per_core,
                "mem_used_mb": round(mem.used / (1024 * 1024), 1),
                "mem_pct": mem.percent,
                "temp_c": temp,
                "pose_count": self.pose_count,
            }
            self.rows.append(row)

            csv_row = [row["elapsed_s"], row["total_cpu_pct"]] + per_core + [
                row["mem_used_mb"], row["mem_pct"],
                row["temp_c"] if row["temp_c"] is not None else "",
                row["pose_count"],
            ]
            self.csv_writer.writerow(csv_row)
            self.csv_file.flush()

            time.sleep(max(0, SAMPLE_INTERVAL - 0.4))

    # ---- Periodic console output ----
    def _print_status(self):
        if not self.rows:
            return
        last = self.rows[-1]
        window = self.rows[-10:]
        avg_cpu = sum(r["total_cpu_pct"] for r in window) / len(window)
        t = last["temp_c"]
        temp_str = f"{t:.1f}°C" if t is not None else "n/a"
        self.get_logger().info(
            f"t={last['elapsed_s']:.0f}s | CPU {last['total_cpu_pct']:.1f}% "
            f"(avg5s {avg_cpu:.1f}%) | Mem {last['mem_used_mb']:.0f}MB "
            f"({last['mem_pct']:.1f}%) | Temp {temp_str} | "
            f"Poses {last['pose_count']}"
        )

    # ---- Shutdown & report ----
    def shutdown(self):
        self.monitoring = False
        self.monitor_thread.join(timeout=3)
        self.csv_file.close()

        if not self.rows:
            print("No samples collected.")
            return

        cpus = [r["total_cpu_pct"] for r in self.rows]
        mems = [r["mem_used_mb"] for r in self.rows]
        temps = [r["temp_c"] for r in self.rows if r["temp_c"] is not None]

        summary = {
            "date": datetime.now().isoformat(),
            "duration_s": round(self.rows[-1]["elapsed_s"], 1),
            "samples": len(self.rows),
            "pose_updates": self.pose_count,
            "map_loaded": self.map_received,
            "num_cores": self.num_cores,
            "cpu_total_pct": {
                "mean": round(sum(cpus) / len(cpus), 1),
                "max": round(max(cpus), 1),
                "min": round(min(cpus), 1),
                "p95": round(sorted(cpus)[int(len(cpus) * 0.95)], 1),
            },
            "memory_mb": {
                "mean": round(sum(mems) / len(mems), 1),
                "max": round(max(mems), 1),
            },
            "temperature_c": {
                "mean": round(sum(temps) / len(temps), 1) if temps else None,
                "max": round(max(temps), 1) if temps else None,
            },
            "csv_file": CSV_PATH,
        }

        with open(JSON_PATH, "w") as f:
            json.dump(summary, f, indent=2)

        total_avail = self.num_cores * 100
        used = summary["cpu_total_pct"]["mean"]
        remaining = total_avail - used

        print()
        print("=" * 62)
        print("  LOCALIZATION CPU BENCHMARK — FINAL REPORT")
        print("=" * 62)
        print(f"  Duration          : {summary['duration_s']:.0f} s")
        print(f"  Samples collected : {summary['samples']}")
        print(f"  Pose updates      : {summary['pose_updates']}")
        print(f"  Map loaded        : {summary['map_loaded']}")
        print("-" * 62)
        print(f"  Cores             : {self.num_cores}  (total capacity = {total_avail}%)")
        print(f"  CPU avg           : {summary['cpu_total_pct']['mean']:.1f}%")
        print(f"  CPU max (peak)    : {summary['cpu_total_pct']['max']:.1f}%")
        print(f"  CPU p95           : {summary['cpu_total_pct']['p95']:.1f}%")
        print(f"  CPU min           : {summary['cpu_total_pct']['min']:.1f}%")
        print("-" * 62)
        print(f"  Memory avg        : {summary['memory_mb']['mean']:.0f} MB")
        print(f"  Memory max        : {summary['memory_mb']['max']:.0f} MB")
        if summary["temperature_c"]["max"] is not None:
            print(f"  Temp avg          : {summary['temperature_c']['mean']:.1f}°C")
            print(f"  Temp max          : {summary['temperature_c']['max']:.1f}°C")
        else:
            print("  Temp              : n/a (sensor not available)")
        print("-" * 62)
        print(f"  >> CPU HEADROOM for other modules: ~{remaining:.0f}% of {total_avail}%")
        print(f"     (camera, planning, control, etc.)")
        print("=" * 62)
        print(f"  CSV log  : {CSV_PATH}")
        print(f"  JSON     : {JSON_PATH}")
        print("=" * 62)


def main():
    rclpy.init()
    monitor = LocalizationCPUMonitor()
    try:
        rclpy.spin(monitor)
    except (KeyboardInterrupt, rclpy.executors.ExternalShutdownException):
        pass
    finally:
        monitor.shutdown()
        monitor.destroy_node()
        try:
            rclpy.shutdown()
        except Exception:
            pass


if __name__ == "__main__":
    main()
