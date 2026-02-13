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

# Setup entrypoint
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Create directories for data
RUN mkdir -p /workspace/maps /workspace/logs /workspace/test_data

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]