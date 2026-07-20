SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# knobs (also read by the scripts from the environment):
#   make gate-2 COPY_MODE=partclone
#   make run-client CRYPT=1 COPY_MODE=partclone
export CRYPT ?= 0
export COPY_MODE ?= dd

.PHONY: help bootstrap check rootfs rootfs-crypt initramfs initramfs-client initramfs-target \
        net net-down target-up target-down run-target run-client measure \
        gate-0 gate-1 gate-2 gate-2.5 gate-3 serial-target serial-client clean distclean

help: ## show this help
	@grep -hE '^[a-zA-Z0-9_.-]+:.*?## ' $(MAKEFILE_LIST) | \
	awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-18s\033[0m %s\n", $$1, $$2}'

bootstrap: ## install missing distro packages — the ONLY host change (prompts first)
	./bootstrap.sh

check: ## verify kernel configs + tools (read-only)
	./check-kernel.sh

# ---------------------------------------------------------------- build
rootfs: ## build plaintext payload image (target/rootfs.img)
	CRYPT=0 ./target/build-rootfs.sh

rootfs-crypt: ## build LUKS payload image (target/rootfs-crypt.img, stage 2.5)
	CRYPT=1 ./target/build-rootfs.sh

initramfs: initramfs-target initramfs-client ## build both initramfs images

initramfs-target: ## build the target VM's initramfs OS
	./target/build-initramfs.sh

initramfs-client: ## build the client initramfs (CRYPT=1 bakes in the LUKS key)
	./client/build-initramfs.sh

# ---------------------------------------------------------------- runtime
net: ## create rdb-br0 + taps (runtime-only; nothing persists)
	./qemu/net-setup.sh

net-down: ## remove rdb-br0 + taps
	./qemu/net-teardown.sh

target-up: ## boot target VM (daemonized) and wait for TARGET-READY
	./qemu/run-target.sh --daemon
	. ./env.sh && ./qemu/serial-expect.py "$$STATE_DIR/target.serial" wait TARGET-READY \
	    --timeout "$$TARGET_READY_TIMEOUT" \
	    --logfile "$$ARTIFACTS_DIR/target/serial-target.log"

target-down: ## stop the target VM
	@if [ -f run/target.pid ]; then \
	    kill "$$(cat run/target.pid)" 2>/dev/null || true; rm -f run/target.pid; \
	    echo "target stopped"; \
	else \
	    echo "target not running"; \
	fi

run-target: ## boot target VM in the foreground (debugging)
	./qemu/run-target.sh

run-client: ## boot client VM in the foreground — full stage 1→2 pivot
	./qemu/run-client.sh

measure: ## timeline table from the latest client run
	./measure/parse-timeline.sh

# ---------------------------------------------------------------- gates
gate-0: ## stage-0 DoD: nvme discover/connect/list from the host
	./gates/gate-0.sh

gate-1: ## build sanity: initramfs contents complete
	./gates/gate-1.sh

gate-2: ## stage-2 DoD: full client pivot (plaintext), BOOT-PROOF verified
	./gates/gate-2.sh

gate-2.5: ## stage-2.5 DoD: full client pivot off the LUKS image
	./gates/gate-2.5.sh

gate-3: ## stage-3 DoD (netboot) — stub, deferred per AGENT.md
	./gates/gate-3.sh

# ---------------------------------------------------------------- debug
serial-target: ## attach to the target VM's serial console (Ctrl-C to detach)
	socat -,rawer UNIX-CONNECT:run/target.serial

serial-client: ## attach to the client VM's serial console (Ctrl-C to detach)
	socat -,rawer UNIX-CONNECT:run/client.serial

# ---------------------------------------------------------------- cleanup
clean: ## remove built images + per-run state (keeps target/luks.key)
	rm -f target/rootfs.img target/rootfs-crypt.img target/boot-proof.uuid
	rm -f target/initramfs-target.img client/initramfs-rdmaboot.img client/local.img
	rm -rf run
	find measure/artifacts -mindepth 1 ! -name .gitkeep -delete

distclean: clean ## clean + remove the LUKS keyfile
	rm -f target/luks.key
