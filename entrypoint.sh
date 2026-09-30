#!/usr/bin/env bash
# Generate the opencode config from what the Ollama server currently holds,
# then hand over to opencode.
set -euo pipefail

# opencode is exec'd directly rather than from a login shell, so the image's
# profile.d umask never runs.
umask 002

CONFIG="${HOME}/.config/opencode/opencode.json"
opencode-config > "${CONFIG}"
if ! jq -e '.model' "${CONFIG}" >/dev/null; then
    echo "!! ${OPENAGENT_MODEL} is not a tool-capable model on ${OLLAMA_HOST}" >&2
    exit 1
fi

exec opencode "$@"
