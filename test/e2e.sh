#!/usr/bin/env bash
# Run a one-shot opencode session through run.sh. The assertions are on the
# plumbing: exit cleanly, the model responds, tool calls carry reasoning, the
# guards plugin denies worktrees outside the repo, permissions are
# auto-approved, and the server stops when the session exits.
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

DIAG_LOG="${OUT}/diagnostics.log"
: >"${DIAG_LOG}"

ts() { date '+%Y-%m-%dT%H:%M:%S%z' | tee -a "${DIAG_LOG}"; }

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${DIAG_LOG}" >&2; }

server_ok() {
    docker exec "${OLLAMA_NAME}" ollama list >/dev/null 2>&1 &&
        docker exec "${OLLAMA_NAME}" curl -sf http://localhost:11434/api/tags >/dev/null 2>&1
}

collect_diags() {
    log "Collecting diagnostics..."
    docker stats --no-stream "${OLLAMA_NAME}" 2>/dev/null >>"${OUT}/docker_stats.log" || true
    docker inspect "${OLLAMA_NAME}" 2>/dev/null >"${OUT}/docker_inspect.log" || true
    docker events --since "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S.%NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --filter "container=${OLLAMA_NAME}" 2>/dev/null >"${OUT}/docker_events.log" || true
    cat /proc/meminfo 2>/dev/null >"${OUT}/host_meminfo.log" || true
    if command -v free >/dev/null 2>&1; then
        free -m 2>/dev/null >"${OUT}/host_free.log" || true
    fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi 2>/dev/null >"${OUT}/nvidia_smi.log" || true
    fi
}

cleanup() {
    docker logs "${OLLAMA_NAME}" >"${OUT}/server.log" 2>&1 || true
    [[ -d "${OUT}/server-tmp" ]] ||
        docker cp -q "${OLLAMA_NAME}:/tmp" "${OUT}/server-tmp" 2>/dev/null || true
    collect_diags
    docker rm -f "${OLLAMA_NAME}" >/dev/null 2>&1 || true
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'echo "!! e2e failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
rm -rf "${OUT}/server-tmp"

cd "${ROOT}"

# --- preflight: verify server and model ---
log "Preflight check"
ts
if ! server_ok; then
    log "Ollama server not ready"
    collect_diags
    exit 1
fi
docker exec "${OLLAMA_NAME}" ollama list 2>/dev/null >"${OUT}/models_list.log" || true
log "Preflight ok"
ts

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

# Helper: run a step with timing and one retry on failure.
run_step() {
    local name="$1" prompt="$2"
    shift 2
    local start elapsed
    start="$(date +%s)"

    log "Step ${name}: starting"
    ts

    STATUS=0
    ./run.sh run "${prompt}" </dev/null 2>"${OUT}/${name}_stderr.log" |
        sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' >"${OUT}/${name}.log" || STATUS=$?
    elapsed=$(( $(date +%s) - start ))
    log "Step ${name}: exit=${STATUS} time=${elapsed}s"

    if [[ "${STATUS}" -ne 0 ]]; then
        log "Step ${name}: retrying..."
        ts
        start="$(date +%s)"
        STATUS=0
        ./run.sh run "${prompt}" </dev/null 2>"${OUT}/${name}_stderr_retry.log" |
            sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' >"${OUT}/${name}_retry.log" || STATUS=$?
        elapsed=$(( $(date +%s) - start ))
        log "Step ${name}: retry exit=${STATUS} time=${elapsed}s"
        [[ "${STATUS}" -eq 0 ]] || {
            log "Step ${name}: failed after retry with exit ${STATUS}"
            collect_diags
            exit "${STATUS}"
        }
    fi
}

# --- step 1: basic session ---
run_step "e2e" \
    "Use the bash tool to run: echo PONG. Then reply with its output."
awk -v banner="> build · ${OPENAGENT_MODEL}" '
    index($0, banner) { seen = 1; next }
    seen && NF { reply = 1 }
    END { exit !reply }' "${OUT}/e2e.log"

# Verify server is still healthy after step 1
if ! server_ok; then
    log "Step 1 post-check: server unhealthy"
    collect_diags; exit 1
fi

# --- step 2: worktree guard ---
run_step "e2e-guard" \
    "Use the bash tool to run: git worktree add /tmp/elsewhere. Then reply with its output."
grep -q "worktrees must live inside the session's repo" "${OUT}/e2e-guard.log"
[[ ! -e "${SESSION_TMP}/elsewhere" ]]

# --- step 3: auto-approve permissions ---
run_step "e2e-auto" \
    "Use the bash tool to run: cat /etc/os-release. Then reply with its output."
grep -q "VERSION_CODENAME" "${OUT}/e2e-auto.log"
if grep -q "auto-rejecting" "${OUT}/e2e-auto.log"; then exit 1; fi

# server log and request bodies are in test/out/ server.log and server-tmp
[[ "$(docker inspect -f '{{.State.Running}}' "${OLLAMA_NAME}")" == false ]]
cat "${OUT}"/server-tmp/ollama-request-logs-*/*v1_chat_completions_body.json |
    jq -se '[.[].messages[] | select(.role == "assistant" and .tool_calls)]
        | length > 0 and all(.reasoning != null and .reasoning != "" and .reasoning_content == null)'

# the session's venv persists in its /tmp mount with the numeric stack
VENV="${SESSION_TMP}/venv"
if ! docker run --rm -v "${VENV}:/tmp/venv:ro" --entrypoint /tmp/venv/bin/python \
        "${IMAGE:-openagent:local}" -c 'import numpy, scipy, sklearn'; then
    echo "!! venv numeric stack import failed" >&2
    exit 1
fi
echo ">> e2e ok" >&2
