FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 nftables conntrack procps iputils-ping python3 \
    && rm -rf /var/lib/apt/lists/*

COPY telar-proxy /usr/local/bin/telar-proxy
COPY network-tests /tests/network-tests
COPY server.py client.py ipv6_extensions.py /tests/
COPY tls-fixtures /tests/tls-fixtures
