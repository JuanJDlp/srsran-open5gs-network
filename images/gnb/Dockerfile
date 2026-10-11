# srsRAN Project gNB with ZeroMQ RF driver (no UHD).
# Build deps taken from srsRAN_Project/docker/scripts/install_dependencies.sh @ release_24_10_1.
ARG UBUNTU_VERSION=22.04

FROM ubuntu:${UBUNTU_VERSION} AS builder
ARG SRSRAN_TAG=release_24_10_1
ARG MARCH=native
ARG JOBS=8
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git cmake make gcc g++ pkg-config \
      libfftw3-dev libmbedtls-dev libsctp-dev libyaml-cpp-dev libgtest-dev libzmq3-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${SRSRAN_TAG} https://github.com/srsran/srsRAN_Project.git /src
WORKDIR /src/build
RUN cmake .. -DCMAKE_BUILD_TYPE=Release -DENABLE_ZEROMQ=ON -DENABLE_UHD=OFF \
      -DBUILD_TESTS=OFF -DMARCH=${MARCH} -DCMAKE_INSTALL_PREFIX=/opt/srs \
    && make -j"${JOBS}" gnb \
    && install -D apps/gnb/gnb /opt/srs/bin/gnb

FROM ubuntu:${UBUNTU_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      libfftw3-single3 libmbedtls14 libmbedcrypto7 libmbedx509-1 libsctp1 libyaml-cpp0.7 libzmq5 \
      iproute2 iputils-ping procps \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/srs/bin/gnb /usr/local/bin/gnb
RUN test -x /usr/local/bin/gnb && ! ldd /usr/local/bin/gnb | grep "not found"
ENTRYPOINT ["gnb"]
