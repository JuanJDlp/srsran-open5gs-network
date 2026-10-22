# Open5GS WebUI built from source (ARM64 hosts, where gradiant/open5gs-webui:2.7.7 is not published).
# Same layout as the gradiant image: /opt/open5gs-webui, `node server/index.js`, port 9999, DB_URI env.
ARG NODE_IMAGE=node:20.18.0-bookworm-slim

FROM ${NODE_IMAGE} AS builder
ARG OPEN5GS_TAG=v2.7.7
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${OPEN5GS_TAG} https://github.com/open5gs/open5gs.git /src
WORKDIR /src/webui
RUN npm ci --no-audit --no-fund && npm run build

FROM ${NODE_IMAGE}
COPY --from=builder /src/webui /opt/open5gs-webui
WORKDIR /opt/open5gs-webui
ENV NODE_ENV=production HOSTNAME=0.0.0.0 PORT=9999 DB_URI=mongodb://mongo/open5gs
CMD ["node", "server/index.js"]
