# Example custom Linux runner flavor: the bundled base image plus Node 20.
# The base image is present in the host's local image store, so FROM
# resolves without a registry; RUNNER_VERSION is passed in by bootstrap.sh.
# For an amd64 flavor (LINUX_FLAVOR_<f>_ARCH=amd64), build FROM
# ghrunner-linux-amd64:${RUNNER_VERSION} instead.
ARG RUNNER_VERSION=2.337.0
FROM ghrunner-linux:${RUNNER_VERSION}

USER root
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*
USER runner
# Entrypoint is inherited from the base image.
