#!/usr/bin/env bash
# Build and push multi-arch CI image to quay.io/openshift-pipeline/ci
# Requires: docker buildx OR podman with qemu-user-static
set -euo pipefail

IMAGE="${IMAGE:-quay.io/openshift-pipeline/ci}"
TAG="${TAG:-test}"
# TAG="${TAG:-latest}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64,linux/ppc64le,linux/s390x}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="${BUILDER:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [--docker|--podman]

Build and push ${IMAGE}:${TAG} for: ${PLATFORMS}

  --docker   use docker buildx (all platforms in one build)
  --podman   use podman (one build per platform, then manifest push)

If omitted, docker buildx is used when available, otherwise podman.

Environment: IMAGE TAG PLATFORMS BUILDER=docker|podman
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker) BUILDER=docker; shift ;;
    --podman) BUILDER=podman; shift ;;
    -h|--help) usage ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

if [[ -z "$BUILDER" ]]; then
  if command -v docker &>/dev/null && docker buildx version &>/dev/null; then
    BUILDER=docker
  elif command -v podman &>/dev/null; then
    BUILDER=podman
  else
    die "docker buildx or podman required"
  fi
fi

echo "=== Building multi-arch image ==="
echo "  Image:     ${IMAGE}:${TAG}"
echo "  Platforms: ${PLATFORMS}"
echo "  Builder:   ${BUILDER}"

build_docker() {
  command -v docker &>/dev/null || die "docker not found"
  docker buildx version &>/dev/null || die "docker buildx required"
  docker buildx create --use --name ci-builder 2>/dev/null || true
  docker buildx build \
    --platform "${PLATFORMS}" \
    -t "${IMAGE}:${TAG}" \
    --push \
    "$DIR"
  docker buildx rm ci-builder 2>/dev/null || true
}

build_podman() {
  command -v podman &>/dev/null || die "podman not found"
  podman manifest rm "${IMAGE}:${TAG}" 2>/dev/null || true
  podman manifest create "${IMAGE}:${TAG}"
  local platform arch
  for platform in ${PLATFORMS//,/ }; do
    arch="${platform##*/}"
    echo "  Building ${platform}..."
    podman build --platform="${platform}" -t "${IMAGE}:${arch}" "$DIR"
    podman manifest add "${IMAGE}:${TAG}" "${IMAGE}:${arch}"
  done
  echo "  Pushing manifest..."
  podman manifest push "${IMAGE}:${TAG}" "docker://${IMAGE}:${TAG}"
}

case "$BUILDER" in
  docker) build_docker ;;
  podman) build_podman ;;
  *) die "BUILDER must be docker or podman (got: ${BUILDER})" ;;
esac

echo "=== Done: ${IMAGE}:${TAG} ==="
