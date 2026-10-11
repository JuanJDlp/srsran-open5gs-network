# Packet capture sidecar (runs with network_mode: host).
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      tcpdump tshark iproute2 \
    && rm -rf /var/lib/apt/lists/*
