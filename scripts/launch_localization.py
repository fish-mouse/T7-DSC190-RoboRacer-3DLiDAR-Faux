#!/usr/bin/env python3
"""
Python script to launch localization node and manage the test
"""

import subprocess
import signal
import sys
import time
import os

class LocalizationLauncher:
    def __init__(self):
        self.processes = []
    
    def launch_localization(self, map_path='/workspace/maps/map.pcd'):
        """Launch the localization node"""
        
        # Check if map exists
        if not os.path.exists(map_path):
            print(f"ERROR: Map file not found at {map_path}")
            print("Please provide a .pcd map file in the maps/ directory")
            sys.exit(1)
        
        print(f"Launching localization with map: {map_path}")
        
        # Launch localization
        cmd = [
            'ros2', 'launch',
            'scanmatcher_custom',
            'mapping_robot.launch.py'
        ]
        
        proc = subprocess.Popen(cmd)
        self.processes.append(proc)
        
        print("Localization node launched. PID:", proc.pid)
        return proc
    
    def signal_handler(self, sig, frame):
        """Handle shutdown signals"""
        print("\nShutting down all processes...")
        for proc in self.processes:
            proc.terminate()
        
        # Wait for graceful shutdown
        time.sleep(2)
        
        for proc in self.processes:
            if proc.poll() is None:
                proc.kill()
        
        sys.exit(0)
    
    def run(self):
        """Main run loop"""
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        # Launch localization
        self.launch_localization()
        
        # Keep running
        try:
            while True:
                time.sleep(1)
                # Check if processes are still running
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