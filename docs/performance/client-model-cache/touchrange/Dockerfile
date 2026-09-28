# Linux arm64 image that builds telar and runs the touchrange Valgrind tool.
# touchrange replaces lackey's main, so it runs as `valgrind --tool=lackey`.
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential bzip2 ca-certificates curl xz-utils python3 \
    libsqlite3-dev libbrotli-dev libnghttp2-dev \
    && rm -rf /var/lib/apt/lists/*
RUN curl -sSfL https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz | tar xJ -C /opt \
    && ln -s /opt/zig-aarch64-linux-0.16.0/zig /usr/local/bin/zig
RUN curl -sSfL https://sourceware.org/pub/valgrind/valgrind-3.25.1.tar.bz2 | tar xj -C /opt
COPY lk_main.c /opt/valgrind-3.25.1/lackey/lk_main.c
RUN cd /opt/valgrind-3.25.1 && ./configure --prefix=/opt/vg && make -j8 && make install
