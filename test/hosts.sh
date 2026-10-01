#!/usr/bin/env bash
# Check how run.sh resolves its settings against each host file: a host's
# ${VAR:-value} default beats run.sh's own, and the caller's environment beats
# both.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENAGENT_USERS="$(id -un)"
CONTAINER_GROUP="$(id -gn)"
export OPENAGENT_USERS CONTAINER_GROUP OPENAGENT_DRY_RUN=1
unset OPENAGENT_MODEL OLLAMA_CONTEXT_LENGTH

resolve() {
    env "$@" "${ROOT}/run.sh"
}

expect() {
    local want="$1"
    shift
    if ! grep -qxF -- "${want}" <<<"$(resolve "$@")"; then
        echo "!! $* did not resolve ${want}:" >&2
        resolve "$@" >&2
        exit 1
    fi
}

expect OPENAGENT_MODEL=qwen3:4b OPENAGENT_HOST=nohostfile
expect OLLAMA_CONTEXT_LENGTH=32768 OPENAGENT_HOST=nohostfile
expect OPENAGENT_MODEL=qwen3.6:27b-coding OPENAGENT_HOST=hovercraft
expect OLLAMA_CONTEXT_LENGTH=131072 OPENAGENT_HOST=hovercraft
expect 'OLLAMA_DOCKER_ARGS=--gpus all' OPENAGENT_HOST=hovercraft
expect OPENAGENT_MODEL=qwen3:8b OPENAGENT_HOST=hovercraft OPENAGENT_MODEL=qwen3:8b
expect OLLAMA_CONTEXT_LENGTH=8192 OPENAGENT_HOST=hovercraft OLLAMA_CONTEXT_LENGTH=8192
expect OPENAGENT_MODEL=qwen3:4b OPENAGENT_HOST=defroster
echo ">> hosts ok" >&2
