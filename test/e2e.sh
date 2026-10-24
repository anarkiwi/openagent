#!/usr/bin/env bash
# Run a one-shot opencode prompt through run.sh against its own Ollama server,
# network and scratch directory. The assertions are on the plumbing, not the
# wording of a small model's answer: opencode exits cleanly, the reply comes
# from the requested Ollama model, and it is not empty; once the model has
# called a tool, the follow-up request carries its reasoning in the field
# Ollama reads; the guards plugin denies a worktree outside the repo; a
# permission request is auto-approved; and the server stops when the session,
# its only one, exits.
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

# The server's log and request bodies are kept under test/out, which CI
# uploads when a check fails.
cleanup() {
    docker logs "${OLLAMA_NAME}" >"${OUT}/server.log" 2>&1 || true
    [[ -d "${OUT}/server-tmp" ]] ||
        docker cp -q "${OLLAMA_NAME}:/tmp" "${OUT}/server-tmp" 2>/dev/null || true
    docker rm -f "${OLLAMA_NAME}" >/dev/null 2>&1 || true
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'echo "!! e2e failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
rm -rf "${OUT}/server-tmp"

cd "${ROOT}"
# Seed the session's venv as one left by an image with another python: its
# interpreter link and scripts still run, but its packages are under a
# site-packages the current python never reads, so the entrypoint must rebuild
# it rather than reach for its pip.
SESSION_TMP="${SCRATCH}/tmp/openagent-$(docker info -f '{{.Name}}' | cut -d. -f1)-$(basename "${ROOT}")"
STALE="${SESSION_TMP}/venv"
rm -rf "${STALE}"
mkdir -p "${STALE}/bin" "${STALE}/lib/python3.0/site-packages/pip"
ln -s /usr/bin/python3 "${STALE}/bin/python"
printf 'home = /usr/bin\ninclude-system-site-packages = false\nversion = 3.0.0\n' \
    >"${STALE}/pyvenv.cfg"
# shellcheck disable=SC2016
printf 'export VIRTUAL_ENV=/tmp/venv PATH="/tmp/venv/bin:${PATH}"\n' >"${STALE}/bin/activate"
printf '#!/tmp/venv/bin/python\nfrom pip._internal.cli.main import main\nmain()\n' >"${STALE}/bin/pip"
chmod +x "${STALE}/bin/pip"
./run.sh run "Use the bash tool to run: echo PONG. Then reply with its output." </dev/null 2>&1 |
    sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' >"${OUT}/e2e.log"
awk -v banner="> build · ${OPENAGENT_MODEL}" '
    index($0, banner) { seen = 1; next }
    seen && NF { reply = 1 }
    END { exit !reply }' "${OUT}/e2e.log"
# The guards plugin runs in the session: the worktree guard denies a worktree
# outside the repo and the model sees the reason in place of a result.
./run.sh run "Use the bash tool to run: git worktree add /tmp/elsewhere. Then reply with its output." </dev/null 2>&1 |
    sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' >"${OUT}/e2e-guard.log"
grep -q "worktrees must live inside the session's repo" "${OUT}/e2e-guard.log"
[[ ! -e "${SESSION_TMP}/elsewhere" ]]
# Permissions are auto-approved: cat outside the working directory asks for
# external_directory, which run would otherwise reject.
./run.sh run "Use the bash tool to run: cat /etc/os-release. Then reply with its output." </dev/null 2>&1 |
    sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' >"${OUT}/e2e-auto.log"
grep -q "VERSION_CODENAME" "${OUT}/e2e-auto.log"
if grep -q "auto-rejecting" "${OUT}/e2e-auto.log"; then exit 1; fi
[[ "$(docker inspect -f '{{.State.Running}}' "${OLLAMA_NAME}")" == false ]]
docker cp -q "${OLLAMA_NAME}:/tmp" "${OUT}/server-tmp"
cat "${OUT}"/server-tmp/ollama-request-logs-*/*v1_chat_completions_body.json |
    jq -se '[.[].messages[] | select(.role == "assistant" and .tool_calls)]
        | length > 0 and all(.reasoning != null and .reasoning != "" and .reasoning_content == null)'
# The session's venv persists in its /tmp mount with the numeric stack in it.
VENV="${SESSION_TMP}/venv"
docker run --rm -v "${VENV}:/tmp/venv:ro" --entrypoint /tmp/venv/bin/python \
    "${IMAGE:-openagent:local}" -c 'import numpy, scipy, sklearn'
echo ">> e2e ok" >&2
