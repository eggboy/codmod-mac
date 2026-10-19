#!/usr/bin/env bash
# Build/upgrade the codmod image with Apple's `container` CLI.
#   ./build.sh            -> newest codmod release
#   ./build.sh 0.9.1      -> specific codmod release
# Produces tags codmod:<version> and codmod:latest.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-$(curl -fsSL https://storage.googleapis.com/codmod-release/latest | tr -d '[:space:]')}"
echo "Building codmod ${VERSION}"

# --pull refreshes the Ubuntu base image (security updates).
container build --pull --platform linux/amd64 \
  --build-arg CODMOD_VERSION="${VERSION}" \
  -t "codmod:${VERSION}" -t codmod:latest .

container run --rm --platform linux/amd64 codmod:latest --version 2>/dev/null | tail -n1
