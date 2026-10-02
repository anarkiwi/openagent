#!/usr/bin/env bash
# Run a one-shot opencode prompt through run.sh against its own Ollama server,
# network and scratch directory. The assertions are on the plumbing, not the
# wording of a small model's answer: opencode exits cleanly, the reply comes
# from the requested Ollama model, and it is not empty; once the model has
# called a tool, the follow-up request carries its reasoning in the field
# Ollama reads; and the server stops when the session, its only one, exits.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/test/out"
mkdir -p "${OUT}"

OPENAGENT_USERS="$(id -un)"
CONTAINER_GROUP="$(id -gn)"
export OPENAGENT_USERS CONTAINER_GROUP
export SCRATCH="${E2E_SCRATCH:-${OUT}/scratch}"
export OLLAMA_NAME=openagent-ollama-e2e
export NETWORK=openagent-e2e
export OPENAGENT_MODEL="${E2E_MODEL:-qwen3:0.6b}"
export OLLAMA_CONTEXT_LENGTH="${E2E_CONTEXT_LENGTH:-16384}"
export OLLAMA_DEBUG_LOG_REQUESTS=1

cleanup() {
    docker rm -f "${OLLAMA_NAME}" >/dev/null 2>&1 || true
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "${ROOT}"
./run.sh run "Use the bash tool to run: echo PONG. Then reply with its output." </dev/null 2>&1 |
    sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' >"${OUT}/e2e.log"
awk -v banner="> build · ${OPENAGENT_MODEL}" '
    index($0, banner) { seen = 1; next }
    seen && NF { reply = 1 }
    END { exit !reply }' "${OUT}/e2e.log"
[[ "$(docker inspect -f '{{.State.Running}}' "${OLLAMA_NAME}")" == false ]]
rm -rf "${OUT}/server-tmp"
docker cp -q "${OLLAMA_NAME}:/tmp" "${OUT}/server-tmp"
cat "${OUT}"/server-tmp/ollama-request-logs-*/*v1_chat_completions_body.json |
    jq -se '[.[].messages[] | select(.role == "assistant" and .tool_calls)]
        | length > 0 and all(.reasoning != null and .reasoning != "" and .reasoning_content == null)'
# The session's venv persists in its /tmp mount with the numeric stack in it.
VENV="$(echo "${SCRATCH}"/tmp/openagent-*/venv)"
docker run --rm -v "${VENV}:/tmp/venv:ro" --entrypoint /tmp/venv/bin/python \
    "${IMAGE:-openagent:local}" -c 'import numpy, scipy, sklearn'
echo ">> e2e ok" >&2
