#!/bin/bash
# parse-rdma-localboot.sh — dracut cmdline hook.
# Parses rd.rdmalocalboot.* into a state file the pre-mount hook sources.
# (A file, not exported vars: under systemd initramfs each hook runs in a
# separate service process, so only the filesystem carries state.)
{
    echo "RDB_TARGET=$(getarg rd.rdmalocalboot.target= || true)"
    echo "RDB_NQN=$(getarg rd.rdmalocalboot.nqn= || true)"
    echo "RDB_DEV=$(getarg rd.rdmalocalboot.dev= || true)"
    echo "RDB_COPYMODE=$(getarg rd.rdmalocalboot.copymode= || true)"
    echo "RDB_IP=$(getarg rd.rdmalocalboot.ip= || true)"
    echo "RDB_CRYPT=$(getarg rd.rdmalocalboot.crypt= || true)"
    echo "RDB_PHASELOG=$(getarg rd.rdmalocalboot.mark= || true)"
    echo "RDB_SAFE_OFFLOADS=$(getarg rd.rdmalocalboot.safeoffloads= || true)"
} > /tmp/rdb-localboot.env
