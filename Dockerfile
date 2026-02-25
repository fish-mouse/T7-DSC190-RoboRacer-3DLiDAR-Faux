FROM ros:humble-perception

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=humble

# Install additional dependencies (PCL, Boost, Eigen already in perception image)
RUN apt-get update && apt-get install -y \
    git \
    python3-pip \
    python3-dev \
    python3-numpy \
    python3-opencv \
    ros-${ROS_DISTRO}-libg2o \
    ros-${ROS_DISTRO}-tf2-sensor-msgs \
    ros-${ROS_DISTRO}-tf2-geometry-msgs \
    ros-${ROS_DISTRO}-tf2-eigen \
    ros-${ROS_DISTRO}-pcl-conversions \
    libceres-dev \
    htop \
    stress-ng \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages for monitoring and processing
RUN pip3 install --no-cache-dir \
    psutil \
    numpy \
    open3d \
    matplotlib \
    pandas \
    pyyaml

# Create workspace
WORKDIR /workspace
RUN mkdir -p /workspace/src

# Clone RoboRacer-3DLiDAR
RUN cd /workspace/src && \
    git clone https://github.com/TUM-AVS/RoboRacer-3DLiDAR.git

# ============================================================
# Patch source for PCL 1.12 / Boost 1.74 / ROS2 Humble compat
# ============================================================

# 1) ndt_omp_ros2: replace deprecated PCL boost headers, add missing boost includes, remove broken align target
RUN NDT_DIR=/workspace/src/RoboRacer-3DLiDAR/lidarslam_ros2/Thirdparty/ndt_omp_ros2 && \
    sed -i 's|#include <pcl/filters/boost.h>|#include <cstddef>\n#include <boost/dynamic_bitset.hpp>\n#include <boost/random.hpp>\n#include <boost/unordered_map.hpp>|g' \
        $NDT_DIR/include/pclomp/voxel_grid_covariance_omp.h \
        $NDT_DIR/include/pclomp/voxel_grid_covariance_omp_impl.hpp && \
    sed -i 's|#include <pcl/registration/boost.h>|#include <cstddef>\n#include <boost/shared_ptr.hpp>\n#include <boost/make_shared.hpp>|g' \
        $NDT_DIR/include/pclomp/gicp_omp_impl.hpp && \
    sed -i 's|#include <pcl/registration/bfgs.h>|#include <pcl/registration/bfgs.h>\n#include <boost/shared_ptr.hpp>\n#include <boost/make_shared.hpp>|g' \
        $NDT_DIR/include/pclomp/gicp_omp.h && \
    python3 -c "import re; p='$NDT_DIR/CMakeLists.txt'; c=open(p).read(); c=re.sub(r'add_executable\(align.*?\)','',c,flags=re.DOTALL); c=re.sub(r'add_dependencies\(align.*?\)','',c,flags=re.DOTALL); c=re.sub(r'target_link_libraries\(align.*?\)','',c,flags=re.DOTALL); c=re.sub(r'ament_target_dependencies\(align.*?\)','',c,flags=re.DOTALL); c=re.sub(r'install\(TARGETS\s+align.*?\)','',c,flags=re.DOTALL); c=re.sub(r'install\(\s*TARGETS\s+align.*?\)','',c,flags=re.DOTALL); open(p,'w').write(c)" && \
    find $NDT_DIR/include $NDT_DIR/src -name "*.h" -o -name "*.hpp" -o -name "*.cpp" | xargs \
        sed -i 's|boost::shared_ptr|std::shared_ptr|g; s|boost::make_shared|std::make_shared|g' && \
    find $NDT_DIR/include $NDT_DIR/src -name "*.h" -o -name "*.hpp" -o -name "*.cpp" | xargs \
        sed -i '1s|^|#include <memory>\n|'

# 2) Fix .h -> .hpp for tf2 headers in all packages that use them
RUN find /workspace/src/RoboRacer-3DLiDAR -name "*.h" -o -name "*.hpp" | xargs \
    sed -i 's|tf2_sensor_msgs/tf2_sensor_msgs.h|tf2_sensor_msgs/tf2_sensor_msgs.hpp|g; s|tf2_geometry_msgs/tf2_geometry_msgs.h|tf2_geometry_msgs/tf2_geometry_msgs.hpp|g; s|tf2_eigen/tf2_eigen.h|tf2_eigen/tf2_eigen.hpp|g'

# 3) graph_based_slam: add missing cmake dependencies
RUN GBS_DIR=/workspace/src/RoboRacer-3DLiDAR/lidarslam_ros2/graph_based_slam && \
    sed -i '/find_package(tf2_ros REQUIRED)/a find_package(tf2_sensor_msgs REQUIRED)\nfind_package(tf2_geometry_msgs REQUIRED)\nfind_package(tf2_eigen REQUIRED)\nfind_package(pcl_conversions REQUIRED)' \
        $GBS_DIR/CMakeLists.txt && \
    sed -i '/^  tf2_ros/a\  tf2_sensor_msgs\n  tf2_geometry_msgs\n  tf2_eigen\n  pcl_conversions' \
        $GBS_DIR/CMakeLists.txt

# 4) lidarslam: add ALL transitive deps needed by scanmatcher + graph_based_slam headers
RUN LS_DIR=/workspace/src/RoboRacer-3DLiDAR/lidarslam_ros2/lidarslam && \
    sed -i '/find_package(scanmatcher REQUIRED)/a find_package(tf2_ros REQUIRED)\nfind_package(tf2_sensor_msgs REQUIRED)\nfind_package(tf2_geometry_msgs REQUIRED)\nfind_package(tf2_eigen REQUIRED)\nfind_package(pcl_conversions REQUIRED)\nfind_package(nav_msgs REQUIRED)\nfind_package(std_srvs REQUIRED)\nfind_package(sensor_msgs REQUIRED)\nfind_package(geometry_msgs REQUIRED)' \
        $LS_DIR/CMakeLists.txt && \
    sed -i '/^  ndt_omp_ros2/{n;s|)|tf2_ros\n  tf2_sensor_msgs\n  tf2_geometry_msgs\n  tf2_eigen\n  pcl_conversions\n  nav_msgs\n  std_srvs\n  sensor_msgs\n  geometry_msgs\n  )|;}' \
        $LS_DIR/CMakeLists.txt

# 5) scanmatcher + scanmatcher_custom: add pcl_conversions to ament_target_dependencies
RUN for SM_DIR in \
        /workspace/src/RoboRacer-3DLiDAR/lidarslam_ros2/scanmatcher \
        /workspace/src/RoboRacer-3DLiDAR/scanmatcher_custom; do \
    if [ -f "$SM_DIR/CMakeLists.txt" ]; then \
        sed -i '/^  ndt_omp_ros2/a\  pcl_conversions' $SM_DIR/CMakeLists.txt; \
    fi; \
    done

# 6) Uncomment static_transform_publisher in launch files (base_link -> livox_frame)
RUN for LAUNCH_FILE in \
        /workspace/src/RoboRacer-3DLiDAR/lidarslam_ros2/lidarslam/launch/lidarslam.launch.py \
        /workspace/src/RoboRacer-3DLiDAR/scanmatcher_custom/launch/mapping_robot.launch.py; do \
    if [ -f "$LAUNCH_FILE" ]; then \
        sed -i "s/# static_transform_publisher_node = Node(/static_transform_publisher_node = Node(/" "$LAUNCH_FILE" && \
        sed -i "s/#     package='tf2_ros',/    package='tf2_ros',/" "$LAUNCH_FILE" && \
        sed -i "s/#     executable='static_transform_publisher',/    executable='static_transform_publisher',/" "$LAUNCH_FILE" && \
        sed -i "s/#     arguments=\['0', '0', '0', '0', '0', '0', 'base_link', 'livox_frame'\],/    arguments=['0', '0', '0', '0', '0', '0', 'base_link', 'livox_frame'],/" "$LAUNCH_FILE" && \
        sed -i "s/# )/)/" "$LAUNCH_FILE" && \
        sed -i "s/#static_transform_publisher_node,/static_transform_publisher_node,/" "$LAUNCH_FILE" ; \
    fi; \
    done

# 7) Fix map_path in scanmatcher_custom params to point to container path
RUN sed -i 's|map_path:.*|map_path: "/workspace/maps/map.pcd"|' \
    /workspace/src/RoboRacer-3DLiDAR/scanmatcher_custom/param/mapping_robot.yaml

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
    colcon build --packages-up-to lidarslam scanmatcher_custom --cmake-args -DCMAKE_BUILD_TYPE=Release

# Copy all scripts into the image (self-contained for deployment)
COPY scripts/ /workspace/scripts/

# Setup entrypoint
RUN chmod +x /workspace/scripts/entrypoint.sh
RUN ln -sf /workspace/scripts/entrypoint.sh /entrypoint.sh

# Create directories for data
RUN mkdir -p /workspace/maps /workspace/logs /workspace/test_data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
