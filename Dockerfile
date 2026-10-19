# syntax=docker/dockerfile:1
#
# codmod (Google Cloud Code Modernization assessment CLI) in a small Ubuntu image.
# codmod only ships linux/amd64 + windows/amd64 builds, so this image is amd64
# and runs on Apple silicon through Rosetta.
#
# Build (latest codmod; build.sh resolves "latest" to a real version so the
# download layer is rebuilt only when a new codmod is released):
#   ./build.sh
# Build (pinned codmod version):
#   container build --platform linux/amd64 --build-arg CODMOD_VERSION=1.0.0 -t codmod:1.0.0 .
#
# Available versions: https://storage.googleapis.com/codmod-release?delimiter=/

ARG UBUNTU_VERSION=26.04

# ---------- Stage 1: download & verify codmod ----------
FROM ubuntu:${UBUNTU_VERSION} AS download

ENV DEBIAN_FRONTEND=noninteractive
# "latest" resolves via gs://codmod-release/latest, or set an explicit version (e.g. 1.0.0)
ARG CODMOD_VERSION=latest
ARG CODMOD_BUCKET=https://storage.googleapis.com/codmod-release

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Expected MD5 is published by GCS in the x-goog-hash header (base64 -> hex) and
# verified against the downloaded binary.
RUN set -eux; \
    if [ "${CODMOD_VERSION}" = "latest" ]; then \
        VERSION="$(curl -fsSL "${CODMOD_BUCKET}/latest" | tr -d '[:space:]')"; \
    else \
        VERSION="${CODMOD_VERSION}"; \
    fi; \
    echo "Installing codmod ${VERSION}"; \
    URL="${CODMOD_BUCKET}/${VERSION}/linux/amd64/codmod"; \
    EXPECTED_MD5="$(curl -fsSI "${URL}" | tr -d '\r' | sed -n 's/^x-goog-hash: md5=//Ip' | head -n1 | base64 -d | od -An -tx1 | tr -d ' \n')"; \
    curl -fsSL -o /codmod "${URL}"; \
    ACTUAL_MD5="$(md5sum /codmod | cut -d' ' -f1)"; \
    [ -n "${EXPECTED_MD5}" ] && [ "${EXPECTED_MD5}" = "${ACTUAL_MD5}" ]; \
    chmod 0755 /codmod; \
    echo "${VERSION}" > /codmod.version

# ---------- Stage 2: runtime ----------
FROM ubuntu:${UBUNTU_VERSION}

# codmod is a static binary; it only needs CA certs for HTTPS calls to Google APIs.
# tzdata lets the wrapper pass the Mac's TZ so log/report timestamps match the host.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY --from=download /codmod /usr/local/bin/codmod
COPY --from=download /codmod.version /etc/codmod.version

# Default only; codmod.sh mounts $HOME and $PWD at their host paths and sets -w "$PWD".
WORKDIR /workspace

ENTRYPOINT ["codmod"]
CMD ["--help"]
