#!/usr/bin/env bash
# Check how run.sh resolves its settings against each host file: a host's
# ${VAR:-value} default beats run.sh's own, and the caller's environment beats
# both.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENAGENT_USERS="$(id -un)"
CONTAINER_GROUP="$(id -gn)"
export OPENAGENT_USERS CONTAINER_GROUP OPENAGENT_DRY_RUN=1
unset OPENAGENT_MODEL OLLAMA_CONTEXT_LENGTH OLLAMA_KV_CACHE_TYPE OPENAGENT_MOUNTS SCRATCH \
    OLLAMA_KEEP_ALIVE OPENAGENT_OUTPUT_LIMIT OPENAGENT_THINK OPENAGENT_VISION OPENAGENT_DRAFT

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
expect OLLAMA_KV_CACHE_TYPE=f16 OPENAGENT_HOST=nohostfile
expect OPENAGENT_MODEL=qwen3.8:27b OPENAGENT_HOST=hovercraft
expect OLLAMA_CONTEXT_LENGTH=262144 OPENAGENT_HOST=hovercraft
expect OLLAMA_KV_CACHE_TYPE=q8_0 OPENAGENT_HOST=hovercraft
expect 'OLLAMA_DOCKER_ARGS=--gpus all' OPENAGENT_HOST=hovercraft
expect OPENAGENT_MODEL=qwen3:8b OPENAGENT_HOST=hovercraft OPENAGENT_MODEL=qwen3:8b
expect OLLAMA_CONTEXT_LENGTH=8192 OPENAGENT_HOST=hovercraft OLLAMA_CONTEXT_LENGTH=8192
expect OPENAGENT_MODEL=qwen3.8:27b OPENAGENT_HOST=defroster
expect OLLAMA_CONTEXT_LENGTH=131072 OPENAGENT_HOST=defroster
expect OLLAMA_KV_CACHE_TYPE=q8_0 OPENAGENT_HOST=defroster
expect 'OLLAMA_DOCKER_ARGS=--gpus all' OPENAGENT_HOST=defroster
expect OLLAMA_KEEP_ALIVE=-1 OPENAGENT_HOST=nohostfile
expect OPENAGENT_OUTPUT_LIMIT=32768 OPENAGENT_HOST=nohostfile
expect OPENAGENT_THINK=xhigh OPENAGENT_HOST=nohostfile
expect OPENAGENT_THINK=low OPENAGENT_HOST=hovercraft OPENAGENT_THINK=low
expect OPENAGENT_THINK=xhigh OPENAGENT_HOST=defroster
expect OPENAGENT_VISION= OPENAGENT_HOST=defroster
expect OPENAGENT_VISION=1 OPENAGENT_HOST=defroster OPENAGENT_VISION=1
expect OPENAGENT_DRAFT= OPENAGENT_HOST=hovercraft
expect OPENAGENT_DRAFT=1 OPENAGENT_HOST=hovercraft OPENAGENT_DRAFT=1
expect 'OPENAGENT_MOUNTS=/scratch/openagent /scratch/tmp /scratch/datasets' \
    OPENAGENT_HOST=nohostfile
expect 'OPENAGENT_MOUNTS=/data /models' OPENAGENT_HOST=nohostfile 'OPENAGENT_MOUNTS=/data /models'
echo ">> hosts ok" >&2
