#!/usr/bin/env bash
# Build and push multi-arch CI image to quay.io/openshift-pipeline/ci
# Requires: docker buildx OR podman with qemu-user-static
set -euo pipefail

IMAGE="${IMAGE:-quay.io/openshift-pipeline/ci}"
TAG="${TAG:-test}"
# TAG="${TAG:-latest}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64,linux/ppc64le,linux/s390x}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Building multi-arch image ==="
echo "  Image:     ${IMAGE}:${TAG}"
echo "  Platforms: ${PLATFORMS}"

if command -v docker &>/dev/null && docker buildx version &>/dev/null; then
  echo "  Builder:   docker buildx"
  docker buildx create --use --name ci-builder 2>/dev/null || true
  docker buildx build \
    --platform "${PLATFORMS}" \
    -t "${IMAGE}:${TAG}" \
    --push \
    "$DIR"
  docker buildx rm ci-builder 2>/dev/null || true
elif command -v podman &>/dev/null; then
  echo "  Builder:   podman manifest"
  podman manifest rm "${IMAGE}:${TAG}" 2>/dev/null || true
  podman manifest create "${IMAGE}:${TAG}"
  for platform in ${PLATFORMS//,/ }; do
    arch="${platform##*/}"
    echo "  Building ${platform}..."
    podman build --platform="${platform}" -t "${IMAGE}:${arch}" "$DIR"
    podman manifest add "${IMAGE}:${TAG}" "${IMAGE}:${arch}"
  done
  echo "  Pushing manifest..."
  podman manifest push "${IMAGE}:${TAG}" "docker://${IMAGE}:${TAG}"
else
  echo "ERROR: docker buildx or podman required" >&2
  exit 1
fi

echo "=== Done: ${IMAGE}:${TAG} ==="
