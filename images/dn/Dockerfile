# Data Network (N6) endpoint: ping target and iperf3 server.
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      iperf3 iproute2 iputils-ping procps \
    && rm -rf /var/lib/apt/lists/*
