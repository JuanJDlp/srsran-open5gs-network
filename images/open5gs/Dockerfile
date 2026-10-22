# Open5GS core NFs built from source. Used on ARM64 hosts (Raspberry Pi 5), where
# gradiant/open5gs:2.7.7 is not published. Same layout the compose expects: open5gs-*d in PATH,
# bash (healthchecks) and iproute2/iptables (UPF entrypoint).
# Build deps from the official guide: https://open5gs.org/open5gs/docs/guide/02-building-open5gs-from-sources/
ARG UBUNTU_VERSION=22.04

FROM ubuntu:${UBUNTU_VERSION} AS builder
ARG OPEN5GS_TAG=v2.7.7
ARG JOBS=4
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git python3-pip python3-setuptools python3-wheel ninja-build build-essential \
      flex bison cmake meson pkg-config libsctp-dev libgnutls28-dev libgcrypt-dev libssl-dev libidn-dev \
      libmongoc-dev libbson-dev libyaml-dev libnghttp2-dev libmicrohttpd-dev libcurl4-gnutls-dev \
      libtins-dev libtalloc-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${OPEN5GS_TAG} https://github.com/open5gs/open5gs.git /src
WORKDIR /src
RUN meson setup build --prefix=/opt/open5gs --buildtype=release \
    && ninja -C build -j"${JOBS}" install

FROM ubuntu:${UBUNTU_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libsctp1 libgnutls30 libgcrypt20 libssl3 libidn12 libmongoc-1.0-0 libbson-1.0-0 \
      libyaml-0-2 libnghttp2-14 libmicrohttpd12 libcurl3-gnutls libtins4.0 libtalloc2 \
      iproute2 iptables iputils-ping procps \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/open5gs /opt/open5gs
ENV PATH=/opt/open5gs/bin:$PATH
WORKDIR /opt/open5gs
RUN dirname "$(find /opt/open5gs -name 'libogscore.so*' | head -1)" > /etc/ld.so.conf.d/open5gs.conf \
    && find /opt/open5gs -name 'libfd*.so*' -printf '%h\n' | sort -u >> /etc/ld.so.conf.d/open5gs.conf \
    && ldconfig \
    && for b in /opt/open5gs/bin/open5gs-*d; do ! ldd "$b" | grep "not found" || exit 1; done
