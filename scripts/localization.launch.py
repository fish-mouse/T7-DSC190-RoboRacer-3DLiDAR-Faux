"""
Clean launch file for scanmatcher_custom localization node.
Bypasses the broken launch file baked into the Docker image.
"""

from launch import LaunchDescription
from launch_ros.actions import Node
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration


def generate_launch_description():
    param_file = LaunchConfiguration(
        "mapping_param_dir",
        default="/workspace/scripts/localization_params.yaml",
    )

    return LaunchDescription([
        DeclareLaunchArgument(
            "mapping_param_dir",
            default_value="/workspace/scripts/localization_params.yaml",
        ),
        Node(
            package="scanmatcher_custom",
            executable="scanmatcher_node",
            name="scan_matcher",
            parameters=[param_file],
            remappings=[("/input_cloud", "/livox/lidar")],
            output="screen",
        ),
    ])
