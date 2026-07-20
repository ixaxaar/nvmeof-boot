#!/usr/bin/env bash
# gate-2.5 — stage 2.5 DoD: gate-2 with the LUKS-encrypted image (CRYPT=1).
set -euo pipefail
export CRYPT=1
exec "$(dirname "${BASH_SOURCE[0]}")/gate-2.sh" "$@"
