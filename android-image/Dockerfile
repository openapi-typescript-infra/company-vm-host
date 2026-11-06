# Portable Company Android build environment and ephemeral GitHub Actions
# runner. Its Android SDK/NDK host tools are x86_64. The standard amd64 image
# runs them natively on Kubernetes; the arm64 variant runs Node/Java/Gradle
# natively on Apple silicon and enables Rosetta only at runtime for those
# x86_64 Android tools.
#
# Every toolchain version is a default-less ARG fed from the repo's
# versions.env, so the pins are declared once and this file cannot drift from
# the macOS bake. bootstrap.sh passes them; by hand:
#   container build $(sed -n 's/^\([A-Z0-9_]*=.*\)/--build-arg \1/p' versions.env) ... android-image
# A build without them fails at the guard below, not with empty paths.
#
# KEEP THIS FILE UNDER ~13KB: apple/container caps a Dockerfile at 16384 bytes
# (apple/container#735) and above ~14KB the client just reports "Stream
# unexpectedly closed". Long explanations belong in the README.
ARG NODE_VERSION
FROM docker.io/library/node:${NODE_VERSION}-bookworm

# Build-time knobs that are NOT pins: runner tarball, architecture, and
# whether to warm the Gradle seed (template|none).
ARG RUNNER_VERSION=2.337.0
ARG RUNNER_ARCH=x64
ARG IMAGE_ARCH=amd64
ARG GRADLE_PREWARM=template

# Pins, from versions.env (NODE_VERSION again: pre-FROM ARGs are not in scope).
ARG NODE_VERSION
ARG YARN_VERSION
ARG JAVA_VERSION
ARG EXPO_SDK
ARG ANDROID_COMMAND_LINE_TOOLS
ARG ANDROID_COMMAND_LINE_TOOLS_SHA256
ARG ANDROID_COMPILE_SDK
ARG ANDROID_LEGACY_PLATFORM
ARG ANDROID_BUILD_TOOLS
ARG ANDROID_LEGACY_BUILD_TOOLS
ARG ANDROID_NDK
ARG ANDROID_EXPO_NDK
ARG ANDROID_CMAKE
ARG GCLOUD_VERSION
ARG GCLOUD_AMD64_SHA256
ARG GCLOUD_ARM64_SHA256
ARG EAS_CLI_VERSION
ARG WARP_VERSION
ARG WARP_AMD64_SHA256
ARG WARP_ARM64_SHA256

# printenv, not eval: RUN text is not unescaped, so \$ reaches dash verbatim.
RUN for v in NODE_VERSION YARN_VERSION JAVA_VERSION EXPO_SDK \
             ANDROID_COMMAND_LINE_TOOLS ANDROID_COMMAND_LINE_TOOLS_SHA256 \
             ANDROID_COMPILE_SDK ANDROID_LEGACY_PLATFORM ANDROID_BUILD_TOOLS \
             ANDROID_LEGACY_BUILD_TOOLS ANDROID_NDK ANDROID_EXPO_NDK ANDROID_CMAKE \
             GCLOUD_VERSION GCLOUD_AMD64_SHA256 GCLOUD_ARM64_SHA256 EAS_CLI_VERSION \
             WARP_VERSION WARP_AMD64_SHA256 WARP_ARM64_SHA256; do \
      [ -n "$(printenv "$v")" ] || { echo "android-image: --build-arg $v is required; pass the repo's versions.env (see the header)" >&2; exit 1; }; \
    done

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_NDK_HOME=/opt/android-sdk/ndk/${ANDROID_NDK} \
    JAVA_HOME=/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-${IMAGE_ARCH} \
    GRADLE_USER_HOME=/home/runner/.gradle \
    EAS_LOCAL_BUILD_WORKINGDIR=/home/runner/eas-local-build \
    PATH=/opt/google-cloud-sdk/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/cmake/${ANDROID_CMAKE}/bin:/opt/android-sdk/ndk/${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin:/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-${IMAGE_ARCH}/bin:$PATH

RUN test "$(dpkg --print-architecture)" = "$IMAGE_ARCH" \
    || { echo "android-image architecture mismatch: expected $IMAGE_ARCH" >&2; exit 1; }

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates ccache curl file git git-lfs jq \
        iproute2 libcap2-bin \
        libpcap0.8 libtss2-esys-3.0.2-0 libtss2-tctildr0 make nftables openssh-client \
        "openjdk-${JAVA_VERSION}-jdk-headless" pkg-config python3 python-is-python3 \
        rsync unzip util-linux xz-utils zip zstd \
    && if [ "$IMAGE_ARCH" = amd64 ]; then \
         apt-get install -y --no-install-recommends libc6-i386 lib32stdc++6 lib32z1; \
       else \
         # The SDK/NDK ships Linux x86_64 host binaries even in our arm64
         # image. Apple Container's runtime Rosetta translates their code,
         # while these foreign-arch packages provide the x86_64 ELF loader
         # and shared libraries it expects.
         dpkg --add-architecture amd64; \
         apt-get update; \
         apt-get install -y --no-install-recommends \
           libc6:amd64 libgcc-s1:amd64 libstdc++6:amd64 zlib1g:amd64; \
       fi \
    && rm -rf /var/lib/apt/lists/*

# Optional Cloudflare WARP connection for runtimes with no route to the company's
# private services; inert unless the entrypoint receives enrollment
# credentials. Cloudflare's .deb declares a full desktop UI dependency tree,
# so extract only the headless daemon and CLI (their shared libraries are in
# the apt list above). Checksums from Cloudflare's signed Bookworm index.
RUN curl -fsSL --retry 3 -o /tmp/cloudflare-warp.deb \
        "https://pkg.cloudflareclient.com/pool/bookworm/main/c/cloudflare-warp/cloudflare-warp_${WARP_VERSION}_${IMAGE_ARCH}.deb" \
    && case "$IMAGE_ARCH" in \
         amd64) echo "${WARP_AMD64_SHA256}  /tmp/cloudflare-warp.deb" ;; \
         arm64) echo "${WARP_ARM64_SHA256}  /tmp/cloudflare-warp.deb" ;; \
         *) exit 1 ;; \
       esac | sha256sum -c - \
    && mkdir /tmp/cloudflare-warp-root \
    && dpkg-deb -x /tmp/cloudflare-warp.deb /tmp/cloudflare-warp-root \
    && install -m 0755 /tmp/cloudflare-warp-root/bin/warp-svc /usr/local/bin/warp-svc \
    && install -m 0755 /tmp/cloudflare-warp-root/bin/warp-cli /usr/local/bin/warp-cli \
    && rm -rf /tmp/cloudflare-warp.deb /tmp/cloudflare-warp-root

# Android command-line tools and the exact native toolchain the app's Expo /
# React Native release uses; versions.env explains each pin (why two NDKs,
# why the legacy platform and build-tools).
RUN mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools" \
    && curl -fsSL --retry 3 -o /tmp/android-command-line-tools.zip \
        "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_COMMAND_LINE_TOOLS}_latest.zip" \
    && echo "${ANDROID_COMMAND_LINE_TOOLS_SHA256}  /tmp/android-command-line-tools.zip" | sha256sum -c - \
    && unzip -q /tmp/android-command-line-tools.zip -d /tmp/android-command-line-tools \
    && mv /tmp/android-command-line-tools/cmdline-tools "$ANDROID_SDK_ROOT/cmdline-tools/latest" \
    && rm -rf /tmp/android-command-line-tools /tmp/android-command-line-tools.zip \
    && (yes | sdkmanager --licenses >/dev/null || true)

RUN sdkmanager --install \
        "platform-tools" \
        "platforms;android-${ANDROID_COMPILE_SDK}" \
        "platforms;android-${ANDROID_LEGACY_PLATFORM}" \
        "build-tools;${ANDROID_BUILD_TOOLS}" \
        "ndk;${ANDROID_NDK}" \
        "ndk;${ANDROID_EXPO_NDK}" \
        "cmake;${ANDROID_CMAKE}" \
    && rm -rf /root/.android /root/.cache

# Own layer so this transitive compatibility tool (Braze) does not invalidate
# the much larger platforms/NDKs layer above.
RUN sdkmanager --install "build-tools;${ANDROID_LEGACY_BUILD_TOOLS}" \
    && rm -rf /root/.android /root/.cache

# The yarn GCP auth plugin shells out to gcloud. Versioned, checksummed
# archive so a rebuild cannot silently change the CLI underneath the app.
RUN case "$IMAGE_ARCH" in \
         amd64) gcloud_arch=x86_64; gcloud_sha="${GCLOUD_AMD64_SHA256}" ;; \
         arm64) gcloud_arch=arm; gcloud_sha="${GCLOUD_ARM64_SHA256}" ;; \
         *) exit 1 ;; \
       esac \
    && curl -fsSL --retry 3 -o /tmp/google-cloud-cli.tar.gz \
         "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${GCLOUD_VERSION}-linux-${gcloud_arch}.tar.gz" \
    && echo "${gcloud_sha}  /tmp/google-cloud-cli.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/google-cloud-cli.tar.gz -C /opt \
    && rm /tmp/google-cloud-cli.tar.gz \
    && /opt/google-cloud-sdk/install.sh --quiet \
        --usage-reporting=false \
        --path-update=false \
        --command-completion=false \
        --install-python=false

# Known-good EAS CLI in the portable image. The workflow's expo-github-action
# may install its own over it; pinning that action is a mobile-apps change.
ENV COREPACK_HOME=/opt/corepack \
    YARN_VERSION=${YARN_VERSION}
RUN install -d -m 0755 "$COREPACK_HOME" \
    && corepack enable \
    && corepack prepare "yarn@${YARN_VERSION}" --activate \
    && npm install --global "eas-cli@${EAS_CLI_VERSION}" \
    && npm cache clean --force \
    && chmod -R a+rX "$COREPACK_HOME"

# The runner is part of the artifact so the same image serves this project's
# _IMAGE flavor contract; Kubernetes Jobs keep the entrypoint and pass command
# arguments to use it as a general Android environment.
RUN groupadd --gid 1001 runner \
    && useradd --create-home --uid 1001 --gid 1001 --shell /bin/bash runner \
    && install -d -m 0755 -o runner -g runner /home/runner/runner /ghrunner-scratch

WORKDIR /home/runner/runner
RUN curl -fsSL --retry 3 -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
    && tar -xzf runner.tar.gz \
    && rm runner.tar.gz \
    && ./bin/installdependencies.sh \
    && rm -rf /var/lib/apt/lists/* \
    && chown -R runner:runner /home/runner

# Gradle seed (README "Company Android build image" has the full story): a real
# release build of the stock Expo template for the app's SDK, so a job's first
# Gradle run starts with the wrapper, AGP/Kotlin/KSP, RN + Expo modules and
# the artifact transforms warm. The entrypoint copies it whole into scratch.
# Best-effort, never fails the build; a seed under ~1GB in the "gradle seed:"
# log line means the warm stopped at dependency resolution.
ENV GHRUNNER_GRADLE_SEED=/opt/ghrunner-gradle-seed
RUN install -d -m 0755 "$GHRUNNER_GRADLE_SEED" \
    && if [ "$GRADLE_PREWARM" = template ]; then \
         export GRADLE_USER_HOME="$GHRUNNER_GRADLE_SEED" HOME=/tmp/prewarm-home \
                CI=1 EXPO_NO_TELEMETRY=1 GRADLE_OPTS=-Dorg.gradle.daemon=false; \
         mkdir -p /tmp/prewarm-home \
         && ( cd /tmp \
              && npx --yes create-expo-app@latest prewarm --template "blank-typescript@sdk-${EXPO_SDK}" --yes \
              && cd /tmp/prewarm \
              && npx expo prebuild --platform android --no-install \
              && cd android \
              && ./gradlew --no-daemon --continue :app:bundleRelease -x createBundleReleaseJsAndAssets ) \
            || echo "WARNING: Gradle prewarm did not complete; the seed keeps whatever it fetched" >&2; \
         rm -rf /tmp/prewarm /tmp/prewarm-home /root/.npm \
                "$GHRUNNER_GRADLE_SEED"/.tmp "$GHRUNNER_GRADLE_SEED"/daemon \
                "$GHRUNNER_GRADLE_SEED"/native "$GHRUNNER_GRADLE_SEED"/notifications \
                "$GHRUNNER_GRADLE_SEED"/workers; \
       fi \
    && echo "gradle seed: $(du -sh "$GHRUNNER_GRADLE_SEED" | cut -f1); dists: $(ls "$GHRUNNER_GRADLE_SEED"/wrapper/dists 2>/dev/null | tr '\n' ' ')" \
    && chown -R runner:runner "$GHRUNNER_GRADLE_SEED"

# The pins this image was built with, for verify-android-toolchain and for
# `container run --rm --entrypoint cat <image> /etc/ghrunner-versions.env`.
RUN printf '%s=%s\n' \
        NODE_VERSION "$NODE_VERSION" YARN_VERSION "$YARN_VERSION" JAVA_VERSION "$JAVA_VERSION" \
        EXPO_SDK "$EXPO_SDK" \
        ANDROID_COMPILE_SDK "$ANDROID_COMPILE_SDK" ANDROID_LEGACY_PLATFORM "$ANDROID_LEGACY_PLATFORM" \
        ANDROID_BUILD_TOOLS "$ANDROID_BUILD_TOOLS" ANDROID_LEGACY_BUILD_TOOLS "$ANDROID_LEGACY_BUILD_TOOLS" \
        ANDROID_NDK "$ANDROID_NDK" ANDROID_EXPO_NDK "$ANDROID_EXPO_NDK" ANDROID_CMAKE "$ANDROID_CMAKE" \
        GCLOUD_VERSION "$GCLOUD_VERSION" EAS_CLI_VERSION "$EAS_CLI_VERSION" WARP_VERSION "$WARP_VERSION" \
        RUNNER_VERSION "$RUNNER_VERSION" \
        > /etc/ghrunner-versions.env \
    && chmod 0644 /etc/ghrunner-versions.env

# The app documents an 8 GiB Gradle heap for D8; give the container 16 GiB at
# runtime so it can coexist with Node, EAS and native CMake/NDK work.
RUN install -d -m 0755 -o runner -g runner /home/runner/.gradle \
    && install -d -m 0755 /opt/hermes/build/bin \
    && printf '%s\n' \
        'org.gradle.jvmargs=-Xmx8192m -XX:MaxMetaspaceSize=1024m -XX:+HeapDumpOnOutOfMemoryError -Dfile.encoding=UTF-8' \
        'org.gradle.parallel=true' \
        'org.gradle.daemon=true' \
        'org.gradle.configureondemand=true' \
        'org.gradle.caching=true' \
        > /etc/ghrunner-gradle.properties \
    && printf '%s\n' \
        "export PATH=\"/opt/google-cloud-sdk/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/cmake/${ANDROID_CMAKE}/bin:/opt/android-sdk/ndk/${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin:/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-${IMAGE_ARCH}/bin:\$PATH\"" \
        > /etc/profile.d/company-android-toolchain.sh \
    && cp /etc/ghrunner-gradle.properties /home/runner/.gradle/gradle.properties \
    && chmod 0644 /etc/ghrunner-gradle.properties /etc/profile.d/company-android-toolchain.sh \
    && chown runner:runner /home/runner/.gradle/gradle.properties

COPY entrypoint.sh /entrypoint.sh
COPY hermesc-rosetta /opt/hermes/build/bin/hermesc
COPY verify-toolchain.sh /usr/local/bin/verify-android-toolchain
# The arm64 image is verified at runtime under Apple Container's --rosetta;
# the builder VM has no such bridge, so only the native amd64 build can run
# the check here.
RUN chmod 0755 /entrypoint.sh /opt/hermes/build/bin/hermesc /usr/local/bin/verify-android-toolchain \
    && if [ "$IMAGE_ARCH" = amd64 ]; then /usr/local/bin/verify-android-toolchain; fi

ENTRYPOINT ["/entrypoint.sh"]
