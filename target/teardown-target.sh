#!/usr/bin/env bash
# target/teardown-target.sh — unwind everything setup-target.sh created.
# Idempotent: safe to run when partially (or never) configured.
set -uo pipefail

if [ -f /etc/rdmaboot/env.sh ]; then
    . /etc/rdmaboot/env.sh
else
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    . ./env.sh
fi

SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

CFG=/sys/kernel/config/nvmet

log "tearing down nvmet target $NQN"

# unlink subsystem from port 1
if [ -L "$CFG/ports/1/subsystems/$NQN" ]; then
    $SUDO rm -f "$CFG/ports/1/subsystems/$NQN"
fi

# namespaces
for ns in "$CFG/subsystems/$NQN"/namespaces/*; do
    [ -d "$ns" ] || continue
    echo 0 | $SUDO tee "$ns/enable" >/dev/null 2>&1
    $SUDO rmdir "$ns" 2>/dev/null
done
[ -d "$CFG/subsystems/$NQN" ] && $SUDO rmdir "$CFG/subsystems/$NQN" 2>/dev/null

# port (only if no other subsystems remain linked)
if [ -d "$CFG/ports/1" ]; then
    if ! ls "$CFG/ports/1/subsystems/"* >/dev/null 2>&1; then
        $SUDO rmdir "$CFG/ports/1" 2>/dev/null
    fi
fi

# soft-roce link
if $SUDO rdma link show 2>/dev/null | grep -q "link $RXE_NAME/"; then
    $SUDO rdma link del "$RXE_NAME" 2>/dev/null
fi

log "teardown done"
