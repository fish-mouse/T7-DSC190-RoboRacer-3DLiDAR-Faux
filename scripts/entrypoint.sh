#!/bin/bash
set -e

# Source ROS2
source /opt/ros/humble/setup.bash
source /workspace/install/setup.bash

# Execute command
exec "$@"