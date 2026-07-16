FROM ubuntu:22.04

# Set non-interactive to avoid prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Define fixed versions for reproducibility
# Rust 1.97.0 is specified to ensure compatibility with latest dependencies
# Flutter 3.44.0 is the latest stable (bundles Dart SDK well above the >=3.9.2 requirement)
# flutter_rust_bridge_codegen 2.13.0-beta.4 is the latest beta supporting native-assets
ENV FLUTTER_VERSION="3.44.0"
ENV RUST_VERSION="1.97.0"
ENV ANDROID_SDK_VERSION="11076708"
ENV FRB_CODEGEN_VERSION="2.13.0-beta.4"

# Set paths for global tools
ENV FLUTTER_HOME=/opt/flutter
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH="$FLUTTER_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:/root/.cargo/bin:$PATH"

# This makes the adb client inside the container talk to the adb server
# running on the HOST (either connected to the host's emulator or a
# real device plugged into the host via USB later on).
# Combined with `network_mode: host` in docker-compose.yml, "127.0.0.1"
# here correctly refers to the host machine, not the container itself.
ENV ADB_SERVER_SOCKET=tcp:127.0.0.1:5037

# Install system dependencies and Google Chrome for web testing
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git unzip xz-utils zip libglu1-mesa clang cmake ninja-build \
    pkg-config libssl-dev libgtk-3-dev libwayland-dev libx11-dev \
    openjdk-17-jdk wget gnupg ca-certificates \
    && wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | apt-key add - \
    && sh -c 'echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" >> /etc/apt/sources.list.d/google.list' \
    && apt-get update && apt-get install -y google-chrome-stable \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Rust with the fixed version and build the codegen tool immediately
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${RUST_VERSION} \
    && . /root/.cargo/env \
    && cargo install flutter_rust_bridge_codegen --version ${FRB_CODEGEN_VERSION}

# Install Flutter with the fixed version (latest stable, satisfies Dart SDK >=3.9.2)
RUN git clone https://github.com/flutter/flutter.git $FLUTTER_HOME \
    && cd $FLUTTER_HOME && git checkout ${FLUTTER_VERSION} \
    && flutter config --enable-web --enable-android --no-analytics \
    && flutter precache \
    && flutter --version

# Install Android SDK Command-line tools + platform-tools (adb client)
# + a baseline platform/build-tools so `flutter build apk` also works
# without extra manual steps.
RUN mkdir -p $ANDROID_HOME/cmdline-tools \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip -O /tmp/tools.zip \
    && unzip /tmp/tools.zip -d $ANDROID_HOME/cmdline-tools \
    && mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest \
    && rm /tmp/tools.zip \
    && yes | sdkmanager --licenses \
    && sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"

WORKDIR /workspace