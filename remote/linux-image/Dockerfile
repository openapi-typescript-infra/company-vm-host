# GitHub Actions runner for Linux, run under apple/container. Serves both
# arm64 (native) and amd64 (Rosetta-translated) slots: the target arch is
# selected at build time by `container build --arch <arch>` (which picks the
# right ubuntu base) plus RUNNER_ARCH (which picks the right runner tarball).
# Each container serves exactly one job (JIT config) and is then discarded.
FROM docker.io/library/ubuntu:26.04

ARG RUNNER_VERSION=2.337.0
# actions/runner tarball arch fragment: arm64 -> arm64, amd64 -> x64.
ARG RUNNER_ARCH=arm64
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git git-lfs jq unzip zstd xz-utils sudo \
        build-essential python3 pkg-config openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Jobs commonly expect passwordless sudo on Linux runners; root inside the
# container is still confined to the container's VM.
RUN useradd -m -u 1001 runner \
    && echo 'runner ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/runner

WORKDIR /home/runner/runner
RUN curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
    && tar -xzf runner.tar.gz \
    && rm runner.tar.gz \
    && ./bin/installdependencies.sh \
    && rm -rf /var/lib/apt/lists/* \
    && chown -R runner:runner /home/runner

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

USER runner
ENTRYPOINT ["/entrypoint.sh"]
