#!/usr/bin/env bash
# gate-3 — stage-3 DoD (real PXE netboot instead of -kernel/-initrd).
# Per AGENT.md, netboot/ is not built until gates 0–2 pass. This stub exists
# so `make gate-3` fails loudly-but-honestly instead of silently passing.
echo "[gate-3] SKIPPED: stage 3 (netboot/) is deferred until gates 0-2 pass." >&2
echo "[gate-3] exit code 77 = conventional 'test skipped'." >&2
exit 77
