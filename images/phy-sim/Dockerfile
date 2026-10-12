# Link-level simulators from srsRAN 4G (same PHY library srsUE uses), for the coding analysis:
#   pusch_nr_bler_test : NR PUSCH chain (LDPC + rate matching + QAM + DMRS) over AWGN -> BLER vs SNR per MCS
#   polar_chain_test   : NR Polar code (PBCH/DCI sizes) over AWGN -> word error rate vs SNR
# They do not touch the running network; scripts/analysis/bler.sh drives them.
ARG UBUNTU_VERSION=22.04

FROM ubuntu:${UBUNTU_VERSION} AS builder
ARG SRSRAN4G_TAG=release_25_10
ARG JOBS=8
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git build-essential cmake pkg-config \
      libfftw3-dev libmbedtls-dev libboost-program-options-dev libconfig++-dev libsctp-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${SRSRAN4G_TAG} https://github.com/srsran/srsRAN_4G.git /src
WORKDIR /src
# Upstream test bug: the LLR scaling loop runs over BATCH_SIZE*N values of a BATCH_SIZE*E buffer.
# With E < N (DCI at AL 2/4) it overflows ("double free"); with E > N (PBCH) it leaves LLRs unscaled.
RUN sed -i '/Convert symbols into LLRs/{n;s/BATCH_SIZE \* code.N/BATCH_SIZE * E/}' \
      lib/src/phy/fec/polar/test/polar_chain_test.c \
    && grep -A1 'Convert symbols into LLRs' lib/src/phy/fec/polar/test/polar_chain_test.c | grep -q 'BATCH_SIZE \* E'
WORKDIR /src/build
# pusch_nr_bler_test is EXCLUDE_FROM_ALL upstream, so build the targets explicitly.
RUN cmake .. -DCMAKE_BUILD_TYPE=Release -DENABLE_ZEROMQ=OFF -DENABLE_UHD=OFF -DENABLE_BLADERF=OFF \
      -DENABLE_SOAPYSDR=OFF -DENABLE_GUI=OFF -DENABLE_SRSENB=OFF -DENABLE_SRSEPC=OFF -DENABLE_SRSUE=OFF \
    && make -j"${JOBS}" pusch_nr_bler_test polar_chain_test \
    && mkdir -p /out \
    && cp "$(find . -name pusch_nr_bler_test -type f)" "$(find . -name polar_chain_test -type f)" /out/

FROM ubuntu:${UBUNTU_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libfftw3-single3 libmbedcrypto7 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /out/ /usr/local/bin/
RUN ! ldd /usr/local/bin/pusch_nr_bler_test | grep "not found" && ! ldd /usr/local/bin/polar_chain_test | grep "not found"
