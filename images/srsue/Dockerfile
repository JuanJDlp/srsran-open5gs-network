# srsUE (srsRAN 4G) with ZeroMQ RF plugin, used as a 5G SA UE.
ARG UBUNTU_VERSION=22.04

FROM ubuntu:${UBUNTU_VERSION} AS builder
ARG SRSRAN4G_TAG=release_25_10
ARG JOBS=8
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git build-essential cmake pkg-config \
      libfftw3-dev libmbedtls-dev libboost-program-options-dev libconfig++-dev libsctp-dev libzmq3-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${SRSRAN4G_TAG} https://github.com/srsran/srsRAN_4G.git /src
WORKDIR /src/build
RUN cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/srs \
      -DENABLE_ZEROMQ=ON -DENABLE_UHD=OFF -DENABLE_BLADERF=OFF -DENABLE_SOAPYSDR=OFF \
      -DENABLE_GUI=OFF -DENABLE_SRSENB=OFF -DENABLE_SRSEPC=OFF \
    && make -j"${JOBS}" srsue srsran_rf_zmq \
    && make install   # srsRAN 4G sets CMAKE_SKIP_INSTALL_ALL_DEPENDENCY: build targets first

FROM ubuntu:${UBUNTU_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      libfftw3-single3 libmbedtls14 libmbedcrypto7 libmbedx509-1 libboost-program-options1.74.0 libconfig++9v5 \
      libsctp1 libzmq5 iproute2 iputils-ping iperf3 procps \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/srs /usr/local
RUN ldconfig && test -x /usr/local/bin/srsue && ls /usr/local/lib/libsrsran_rf_zmq.so* \
    && ! ldd /usr/local/bin/srsue | grep "not found"
ENTRYPOINT ["srsue"]
