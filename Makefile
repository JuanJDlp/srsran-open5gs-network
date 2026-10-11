# 5G SA lab (Open5GS + srsRAN Project + srsUE over ZMQ), all in Docker.
#   make build    compile gNB/srsUE images (first time 10-20 min)
#   make up       core -> gNB -> UE, waits for NG Setup and PDU session   (BW=10|15|20 to override)
#   make verify   end-to-end checks V0-V5
#   make capture  pcaps per interface (N2/N3, SBI/N4, N6) while re-attaching the UE
#   make down     stop everything (keeps subscriber DB);  make clean also removes the DB volume
SHELL := /bin/bash
.PHONY: help build up verify down clean logs ps attach-gnb attach-ue configs capture

help:
	@sed -n "2,6p" Makefile

build:
	docker compose --profile ran --profile capture build
	docker compose pull --ignore-buildable

configs:
	scripts/gen-radio-configs.sh

up:
	scripts/up.sh

verify:
	scripts/verify.sh

down:
	scripts/down.sh

clean:
	@read -p "Remove containers AND the subscriber DB volume? [y/N] " a; [[ $$a == y ]] && scripts/down.sh --volumes

ps:
	docker compose --profile ran ps --format 'table {{.Name}}\t{{.Status}}'

logs:
	@for c in amf smf upf gnb ue; do echo "== $$c"; docker logs --tail 15 $$c 2>&1 | sed -r 's/\x1B\[[0-9;?]*[a-zA-Z]//g'; done

attach-gnb:
	@echo "gNB console: press t for metrics, detach with Ctrl-p Ctrl-q"; docker attach gnb

attach-ue:
	@echo "UE console: press t for metrics, detach with Ctrl-p Ctrl-q"; docker attach ue

capture:
	scripts/capture.sh
