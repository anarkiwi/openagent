#!/usr/bin/env bash
# Run a one-shot opencode session through run.sh. The assertions are on the
# plumbing: exit cleanly, the model responds, tool calls carry reasoning, the
# guards plugin denies worktrees outside the repo, permissions are
# auto-approved, and the server stops when the session exits.
set -Eeuo pipefail

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

# A step that runs past the ceiling is a hang, not a slow answer: the timeout
# turns it into a failure whose diagnostics still get collected.
STEP_TIMEOUT="${E2E_STEP_TIMEOUT:-600}"

# run.sh names the session container this way; the failure paths address it
# directly rather than guess from the network listing.
HOST_ID="$(docker info -f '{{.Name}}' | cut -d. -f1)"
SESSION_NAME="openagent-${HOST_ID}-$(basename "${ROOT}")"

DIAG_LOG="${OUT}/diagnostics.log"
: >"${DIAG_LOG}"
# A previous run must not seed this one's record: the server's own files are
# captured once per run, and the append-only samples start from this run.
rm -f "${OUT}/server.log" "${OUT}/server_summary.log" \
    "${OUT}/docker_stats.log" "${OUT}/docker_stats_timeline.log"

ts() {
    local load
    load="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)" || load=""
    printf '%s load=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${load:-?}" | tee -a "${DIAG_LOG}"
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${DIAG_LOG}" >&2; }

# One resource sample every few seconds across the whole run: CPU and memory
# over time separate a slow answer from a wedged one. The stop file ends it,
# and the hard cap does as well, so it can never outlive the script.
STATS_PID=
STATS_STOP="${OUT}/.stop_stats"

start_stats_sampler() {
    if [[ -n "${STATS_PID}" ]]; then
        return 0
    fi
    rm -f "${STATS_STOP}"
    (
        for _ in $(seq 720); do
            if [[ -f "${STATS_STOP}" ]]; then
                break
            fi
            sample="$(timeout 5 docker stats --no-stream --format \
                '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}' 2>/dev/null | tr '\n' ' ; ')" \
                || sample=""
            printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${sample:-no container running}" \
                >>"${OUT}/docker_stats_timeline.log"
            sleep 5
        done
    ) &
    STATS_PID=$!
}

stop_stats_sampler() {
    if [[ -n "${STATS_PID}" ]]; then
        touch "${STATS_STOP}"
        wait "${STATS_PID}" 2>/dev/null || true
    fi
    STATS_PID=
}

DIAG_COLLECTED=0

# Every docker call is bounded: a wedged daemon must not hang the script, and
# docker events streams until --until, so it is bounded on both sides. The
# listing covers the whole e2e network, since a wedged or killed session
# container is as likely a flake as the server; the events filter names both
# containers, and the State block is where an OOM kill shows up.
collect_diags() {
    if [[ "${DIAG_COLLECTED}" == 1 ]]; then
        return 0
    fi
    DIAG_COLLECTED=1
    log "Collecting diagnostics..."
    timeout 30 docker ps -a --filter "network=${NETWORK}" \
        --format '{{.Names}} {{.State}} {{.Status}}' >"${OUT}/docker_ps.log" 2>/dev/null || true
    timeout 30 docker system df >"${OUT}/docker_df.log" 2>/dev/null || true
    timeout 30 docker stats --no-stream "${OLLAMA_NAME}" 2>/dev/null >>"${OUT}/docker_stats.log" || true
    timeout 30 docker inspect "${OLLAMA_NAME}" 2>/dev/null >"${OUT}/docker_inspect.log" || true
    timeout 30 docker inspect -f \
        'oomkilled={{.State.OOMKilled}} exit={{.State.ExitCode}} status={{.State.Status}} error="{{.State.Error}}"' \
        "${SESSION_NAME}" 2>/dev/null >"${OUT}/session_state.log" || true
    timeout 60 docker events \
        --since "$(date -u -d '10 minutes ago' +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --until "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --filter "container=${OLLAMA_NAME}" --filter "container=${SESSION_NAME}" \
        2>/dev/null >"${OUT}/docker_events.log" || true
    # dmesg keeps the kernel's kill records, which docker events do not.
    timeout 30 dmesg 2>/dev/null | tail -n 100 >"${OUT}/dmesg_tail.log" || true
    cat /proc/meminfo 2>/dev/null >"${OUT}/host_meminfo.log" || true
    if command -v free >/dev/null 2>&1; then
        free -m 2>/dev/null >"${OUT}/host_free.log" || true
    fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        timeout 30 nvidia-smi 2>/dev/null >"${OUT}/nvidia_smi.log" || true
    fi
}

# The server's own log and request bodies are the ground truth for what the
# model did; capture them at the moment a failure is known, before anything
# else exits, so the record exists even if the exit path is cut short.
server_capture() {
    if [[ ! -f "${OUT}/server.log" ]]; then
        timeout 60 docker logs "${OLLAMA_NAME}" >"${OUT}/server.log" 2>&1 || true
    fi
    if [[ ! -d "${OUT}/server-tmp" ]]; then
        timeout 300 docker cp -q "${OLLAMA_NAME}:/tmp" "${OUT}/server-tmp" 2>/dev/null || true
    fi
}

# Error and model lines are the server's side of any failure.
server_log_summary() {
    if [[ ! -f "${OUT}/server.log" ]]; then
        return 0
    fi
    grep -Ei 'error|warn|fatal|panic|loading model|loaded model|kv cache|out of memory' \
        "${OUT}/server.log" 2>/dev/null | head -n 40 >"${OUT}/server_summary.log" || true
    log "--- notable server.log lines ---"
    cat "${OUT}/server_summary.log" >&2
}

cleanup() {
    stop_stats_sampler
    server_capture
    collect_diags
    timeout 60 docker rm -f "${OLLAMA_NAME}" >/dev/null 2>&1 || true
    timeout 60 docker rm -f "${SESSION_NAME}" >/dev/null 2>&1 || true
    timeout 60 docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'echo "!! e2e failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
rm -rf "${OUT}/server-tmp"
start_stats_sampler

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

# A failed step's stderr carries the failure's own words; surface them so a
# diagnosis does not hinge on downloading the artifact first.
step_stderr_tail() {
    local name="$1" attempt
    for attempt in "${name}_stderr_retry.log" "${name}_stderr.log"; do
        if [[ -f "${OUT}/${attempt}" ]]; then
            log "--- ${attempt} (tail) ---"
            tail -n 60 "${OUT}/${attempt}" >&2
            break
        fi
    done
}

# Name the step, the failure, and the evidence that explains it, then stop.
fail_step() {
    local name="$1"
    shift
    log "FAIL [${name}] $*"
    step_stderr_tail "${name}"
    server_capture
    server_log_summary
    collect_diags
    exit 1
}

# Helper: run a step with timing and one retry on failure.
run_step() {
    local name="$1" prompt="$2"
    local start elapsed status
    start="$(date +%s)"

    log "Step ${name}: starting"
    ts

    status=0
    timeout -k 10 "${STEP_TIMEOUT}" ./run.sh run "${prompt}" </dev/null \
        2>"${OUT}/${name}_stderr.log" |
        sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' >"${OUT}/${name}.log" || status=$?
    elapsed=$(( $(date +%s) - start ))
    log "Step ${name}: exit=${status} time=${elapsed}s"

    if [[ "${status}" -ne 0 ]]; then
        log "Step ${name}: retrying..."
        # A failed run can leave its session container wedged behind, and the
        # retry would collide with that name; clear it before the retry.
        if timeout 60 docker rm -f "${SESSION_NAME}" >/dev/null 2>&1; then
            log "Step ${name}: removed the previous session container before the retry"
        fi
        ts
        start="$(date +%s)"
        status=0
        timeout -k 10 "${STEP_TIMEOUT}" ./run.sh run "${prompt}" </dev/null \
            2>"${OUT}/${name}_stderr_retry.log" |
            sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' >"${OUT}/${name}_retry.log" || status=$?
        elapsed=$(( $(date +%s) - start ))
        log "Step ${name}: retry exit=${status} time=${elapsed}s"
        if [[ "${status}" -ne 0 ]]; then
            log "Step ${name}: failed after retry with exit ${status}"
            step_stderr_tail "${name}"
            server_capture
            server_log_summary
            collect_diags
            exit "${status}"
        fi
        # Assert on the attempt that decided the step; keep both for post-mortem.
        mv "${OUT}/${name}.log" "${OUT}/${name}_attempt1.log"
        mv "${OUT}/${name}_stderr.log" "${OUT}/${name}_stderr_attempt1.log"
        mv "${OUT}/${name}_retry.log" "${OUT}/${name}.log"
        mv "${OUT}/${name}_stderr_retry.log" "${OUT}/${name}_stderr.log"
        log "Step ${name}: ok on retry"
    fi
}

# --- step 1: basic session ---
run_step "e2e" \
    "Use the bash tool to run: echo PONG. Then reply with its output."
# The server is down after each step by design (run.sh stops it when the
# session exits); the State.Running assertion below covers that.
grep -qi PONG "${OUT}/e2e.log" ||
    grep -qi PONG "${OUT}/e2e_stderr.log" ||
    fail_step e2e "no PONG reply in the e2e logs"

# --- step 2: worktree guard ---
run_step "e2e-guard" \
    "Use the bash tool to run: git worktree add /tmp/elsewhere. Then reply with its output."
grep -q "worktrees must live inside the session's repo" "${OUT}/e2e-guard.log" ||
    fail_step e2e-guard "the guards plugin message is missing from the e2e-guard log"
[[ ! -e "${SESSION_TMP}/elsewhere" ]] ||
    fail_step e2e-guard "a worktree was created outside the repo"

# --- step 3: auto-approve permissions ---
run_step "e2e-auto" \
    "Use the bash tool to run: cat /etc/os-release. Then reply with its output."
grep -q "VERSION_CODENAME" "${OUT}/e2e-auto.log" ||
    fail_step e2e-auto "the reply lacks the os-release content"
if grep -q "auto-rejecting" "${OUT}/e2e-auto.log"; then
    fail_step e2e-auto "a permission was rejected instead of auto-approved"
fi

# The server is down when the last session exits; name which fact is missing.
SERVING="$(docker inspect -f '{{.State.Running}}' "${OLLAMA_NAME}" 2>/dev/null)" ||
    { log "FAIL: the server container is gone after the last session"; server_capture; collect_diags; exit 1; }
if [[ "${SERVING}" != false ]]; then
    log "FAIL: the server is still running after the last session"
    server_capture
    collect_diags
    exit 1
fi

# One request body per inference the server handled; none means the session
# never reached it.
shopt -s nullglob
BODY=("${OUT}"/server-tmp/ollama-request-logs-*/*v1_chat_completions_body.json)
shopt -u nullglob
if [[ ${#BODY[@]} -eq 0 ]]; then
    log "FAIL: no request bodies captured: the session never reached the server"
    server_capture
    collect_diags
    exit 1
fi
if ! cat "${BODY[@]}" |
    jq -se '[.[].messages[] | select(.role == "assistant" and .tool_calls)]
        | length > 0 and all(.reasoning != null and .reasoning != "" and .reasoning_content == null)'; then
    log "FAIL: no assistant tool call in the request bodies carried reasoning"
    server_capture
    collect_diags
    exit 1
fi

# the session's venv persists in its /tmp mount with the numeric stack
VENV="${SESSION_TMP}/venv"
if ! timeout 300 docker run --rm -v "${VENV}:/tmp/venv:ro" --entrypoint /tmp/venv/bin/python \
        "${IMAGE:-openagent:local}" -c 'import numpy, scipy, sklearn'; then
    log "FAIL: the session's venv numeric stack will not import"
    server_capture
    collect_diags
    exit 1
fi
echo ">> e2e ok" >&2
