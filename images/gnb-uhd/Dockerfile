# srsRAN Project gNB with the UHD RF driver (Ettus USRP B200/B210), same release as the ZMQ image.
# UHD comes from Ubuntu 22.04 (libuhd 4.1.0.5, pinned by the base image). The B2xx FPGA/firmware
# images are baked in so the container does not need Internet access when the USRP is plugged in.
ARG UBUNTU_VERSION=22.04

FROM ubuntu:${UBUNTU_VERSION} AS builder
ARG SRSRAN_TAG=release_24_10_1
ARG MARCH=native
ARG JOBS=8
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git cmake make gcc g++ pkg-config \
      libfftw3-dev libmbedtls-dev libsctp-dev libyaml-cpp-dev libgtest-dev \
      libuhd-dev libboost-dev libboost-program-options-dev libboost-thread-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${SRSRAN_TAG} https://github.com/srsran/srsRAN_Project.git /src
WORKDIR /src/build
RUN cmake .. -DCMAKE_BUILD_TYPE=Release -DENABLE_UHD=ON -DENABLE_ZEROMQ=OFF \
      -DBUILD_TESTS=OFF -DMARCH=${MARCH} -DCMAKE_INSTALL_PREFIX=/opt/srs \
    && make -j"${JOBS}" gnb \
    && install -D apps/gnb/gnb /opt/srs/bin/gnb

FROM ubuntu:${UBUNTU_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
# uhd-host: uhd_find_devices / uhd_usrp_probe and the images downloader (B2xx FPGA + FX3 firmware).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libfftw3-single3 libmbedtls14 libmbedcrypto7 libmbedx509-1 libsctp1 libyaml-cpp0.7 \
      libuhd4.1.0 uhd-host python3 iproute2 iputils-ping procps usbutils \
    && uhd_images_downloader -t b2xx \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/srs/bin/gnb /usr/local/bin/gnb
RUN test -x /usr/local/bin/gnb && ! ldd /usr/local/bin/gnb | grep "not found" \
    && ls /usr/share/uhd/images/usrp_b2*_fpga.bin /usr/share/uhd/images/usrp_b200_fw.hex
ENTRYPOINT ["gnb"]
