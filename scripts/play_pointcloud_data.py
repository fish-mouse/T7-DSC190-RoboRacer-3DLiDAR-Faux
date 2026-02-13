#!/usr/bin/env python3
"""
Publish pre-recorded point cloud data for testing without actual LiDAR hardware
"""

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import PointCloud2, PointField
import numpy as np
import struct
import time
import os

class PointCloudPlayer(Node):
    def __init__(self, pcd_file=None):
        super().__init__('pointcloud_player')
        
        self.publisher = self.create_publisher(PointCloud2, '/input_cloud', 10)
        self.timer = self.create_timer(0.1, self.publish_pointcloud)  # 10 Hz
        
        self.pcd_file = pcd_file
        self.frame_id = 'livox_frame'
        self.get_logger().info('PointCloud Player started')
    
    def generate_sample_pointcloud(self):
        """Generate a sample point cloud (for testing without real data)"""
        # Create a simple rectangular room-like point cloud
        points = []
        
        # Floor
        for x in np.linspace(-5, 5, 50):
            for y in np.linspace(-5, 5, 50):
                points.append([x, y, 0.0, 50.0])  # x, y, z, intensity
        
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
        """Create PointCloud2 message from numpy array"""
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
        
        # Pack data
        buffer = []
        for point in points:
            buffer.append(struct.pack('ffff', point[0], point[1], point[2], point[3]))
        
        msg.data = b''.join(buffer)
        
        return msg
    
    def publish_pointcloud(self):
        """Publish point cloud at regular intervals"""
        points = self.generate_sample_pointcloud()
        msg = self.create_pointcloud2_msg(points)
        self.publisher.publish(msg)
        self.get_logger().info(f'Published point cloud with {len(points)} points')

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