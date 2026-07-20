#!/usr/bin/env bash
# qemu/net-setup.sh — dedicated bridge + two taps for the POC. Idempotent.
#
# Safety contract (your desktop stays intact):
#   - only touches interfaces named rdb-*; refuses if they already exist with
#     unexpected config, never touches anything else
#   - no NAT, no IP forwarding, no sysctl, no firewall, no /etc writes
#   - fails loud if our subnet collides with existing routes
#   - fully undone by qemu/net-teardown.sh; nothing survives a reboot anyway
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

# subnet collision check: refuse if any existing interface already uses our IPs
if ip addr show | grep -qE "inet ${SUBNET_PREFIX}\." && ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    die "subnet ${SUBNET_PREFIX}.0/$NETMASK collides with an existing interface — change SUBNET_PREFIX in env.sh"
fi

if ip link show "$BRIDGE" >/dev/null 2>&1; then
    log "$BRIDGE already exists — verifying, not recreating"
    ip -br addr show "$BRIDGE"
    for t in "$TAP_TARGET" "$TAP_CLIENT"; do
        ip link show "$t" >/dev/null 2>&1 || die "$BRIDGE exists but $t missing — run: make net-down && make net"
    done
    exit 0
fi

need_cmd ip

log "creating $BRIDGE (${HOST_IP}/$NETMASK) + taps $TAP_TARGET,$TAP_CLIENT (owner $(id -un))"

sudo ip link add name "$BRIDGE" type bridge
sudo ip addr add "${HOST_IP}/${NETMASK}" dev "$BRIDGE"

for t in "$TAP_TARGET" "$TAP_CLIENT"; do
    sudo ip tuntap add dev "$t" mode tap user "$(id -un)"
    sudo ip link set "$t" master "$BRIDGE"
    sudo ip link set "$t" up
done
sudo ip link set "$BRIDGE" up

log "network up:"
ip -br addr show "$BRIDGE"
ip -br link show "$TAP_TARGET"
ip -br link show "$TAP_CLIENT"
