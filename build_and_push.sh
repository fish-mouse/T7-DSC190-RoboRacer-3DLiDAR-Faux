#!/bin/bash
# Build Docker image for Raspberry Pi (linux/arm64) and push to Docker Hub
#
# Prerequisites:
#   1. Docker Desktop running with buildx support
#   2. Logged in to Docker Hub:  docker login
#
# Usage:
#   ./build_and_push.sh              # build for arm64 and push
#   ./build_and_push.sh --local      # build for current platform only (no push)

set -e

IMAGE="nabilafifahq/lidar-localization-test"
TAG="latest"

echo "=========================================="
echo "Build & Push: $IMAGE:$TAG"
echo "=========================================="

if [[ "$1" == "--local" ]]; then
    echo "Mode: local build (current platform only)"
    echo ""
    docker build -t "$IMAGE:$TAG" .
    echo ""
    echo "Local build complete: $IMAGE:$TAG"
    exit 0
fi

echo "Mode: cross-platform build for linux/arm64 (Raspberry Pi)"
echo ""

# Ensure buildx builder exists
BUILDER_NAME="rpi-builder"
if ! docker buildx inspect "$BUILDER_NAME" > /dev/null 2>&1; then
    echo "Creating buildx builder: $BUILDER_NAME"
    docker buildx create --name "$BUILDER_NAME" --use --driver docker-container
else
    docker buildx use "$BUILDER_NAME"
fi

echo ""
echo "Building and pushing for linux/arm64..."
echo "This will take a while (cross-compilation + push)..."
echo ""

docker buildx build \
    --platform linux/arm64 \
    --tag "$IMAGE:$TAG" \
    --push \
    .

echo ""
echo "=========================================="
echo "SUCCESS!"
echo "=========================================="
echo "Image pushed: $IMAGE:$TAG (linux/arm64)"
echo ""
echo "On the Raspberry Pi car, run:"
echo "  docker pull $IMAGE:$TAG"
echo "=========================================="
