# GitHub Actions runner machine image for docker-capable Linux slots, run
# under apple/container's `machine` feature: a lightweight VM that boots this
# image's systemd as pid 1, with a rootful dockerd inside for jobs that need
# docker (build, testcontainers, compose). One machine is created fresh per
# job and deleted afterward - nothing survives between jobs.
#
# qemu-user binfmt is included as a fallback for amd64-only job containers
# (docker run --platform amd64). It is slower than the Rosetta translation
# the old Lima slots had and has fidelity holes (e.g. postgres does not
# survive it) - prefer multi-arch images, or the linuxvmamd64 slots.
FROM docker.io/library/ubuntu:26.04

ARG RUNNER_VERSION=2.338.2
ENV DEBIAN_FRONTEND=noninteractive
ENV container=container

RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        ca-certificates curl git git-lfs jq unzip zstd xz-utils sudo \
        build-essential python3 pkg-config openssh-client \
        docker.io \
        qemu-user-static binfmt-support \
    && rm -rf /var/lib/apt/lists/*

# Empty machine-id so every machine created from this image gets its own on
# first boot instead of sharing one baked at build time.
RUN >/etc/machine-id && >/var/lib/dbus/machine-id

RUN systemctl set-default multi-user.target \
    && systemctl mask \
        dev-hugepages.mount \
        sys-fs-fuse-connections.mount \
        systemd-update-utmp.service \
        systemd-tmpfiles-setup.service \
        console-getty.service \
    && systemctl enable docker.service binfmt-support.service

# The apple/container machine kernel has no nf_tables NAT support; dockerd
# fails to create its NAT chains with the default (nft) backend.
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Jobs may drive docker with older API clients (docker-java, testcontainers
# pins); modern daemons reject API < 1.40 unless told otherwise.
RUN mkdir -p /etc/systemd/system/docker.service.d \
    && printf '[Service]\nEnvironment=DOCKER_MIN_API_VERSION=1.24\n' \
        > /etc/systemd/system/docker.service.d/min-api.conf

# Jobs commonly expect passwordless sudo on Linux runners; root inside the
# machine is still confined to the machine's VM.
RUN useradd -m -u 1001 runner \
    && usermod -aG docker runner \
    && echo 'runner ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/runner \
    && chmod 440 /etc/sudoers.d/runner \
    && install -d -o runner -g runner /home/runner/tmp

WORKDIR /home/runner/runner
RUN curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" \
    && tar -xzf runner.tar.gz \
    && rm runner.tar.gz \
    && ./bin/installdependencies.sh \
    && rm -rf /var/lib/apt/lists/* \
    && chown -R runner:runner /home/runner

# Replace `machine`'s built-in first-boot user provisioning (which creates a
# guest user mirroring the invoking host account) - the runner user is baked
# above and the host service account must not exist inside the guest.
COPY create-user.sh /etc/machine/create-user.sh
RUN chmod 755 /etc/machine/create-user.sh
