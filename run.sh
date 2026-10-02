#!/usr/bin/env bash
# Build and run an opencode session backed by a local Ollama server.
#
# Two containers: one Ollama server per host (OLLAMA_NAME), shared by every
# session on it and keeping its weights under the shared scratch mount, and
# one opencode container per session, run as the invoking identity with its
# UID/GID and home path so bind-mounted paths keep their ownership. The two
# meet on a user-defined docker network, so the server is never published on
# a host port.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The shared identities exist with the same UID/GID on every host, so keys and
# file ownership follow the account rather than the machine.
CONTAINER_USER="$(id -un)"
OPENAGENT_USERS="${OPENAGENT_USERS:-claude ansible openagent}"
if [[ " ${OPENAGENT_USERS} " != *" ${CONTAINER_USER} "* ]]; then
    echo "!! run.sh must run as one of: ${OPENAGENT_USERS}, not ${CONTAINER_USER}" >&2
    exit 1
fi
CONTAINER_UID="$(id -u)"
CONTAINER_GROUP="${CONTAINER_GROUP:-sw}"
CONTAINER_GID="$(getent group "${CONTAINER_GROUP}" | cut -d: -f3)"
DOCKER_GID="$(getent group docker | cut -d: -f3)"

# The host is the one whose daemon runs the containers, which is not
# hostname when run.sh itself runs inside a container.
HOST="${OPENAGENT_HOST:-$(docker info -f '{{.Name}}')}"
HOST="${HOST%%.*}"
REPO_NAME="$(basename "$(pwd)")"
NAME="openagent-${HOST}-${REPO_NAME}"

# hosts/<hostname>.sh is sourced before the defaults below are applied, so it
# can set its own defaults with ${VAR:-value} and the caller's environment
# still wins over both. It may also append docker flags for the session
# (HOST_DOCKER_ARGS) or the server (OLLAMA_DOCKER_ARGS), such as --gpus.
HOST_DOCKER_ARGS=()
OLLAMA_DOCKER_ARGS=()
HOST_CONFIG="${SCRIPT_DIR}/hosts/${HOST}.sh"
if [[ -f "${HOST_CONFIG}" ]]; then
    # shellcheck disable=SC1090
    source "${HOST_CONFIG}"
fi

SCRATCH="${SCRATCH:-/scratch}"
OLLAMA_DIR="${OLLAMA_DIR:-${SCRATCH}/ollama}"
OLLAMA_NAME="${OLLAMA_NAME:-openagent-ollama}"
NETWORK="${NETWORK:-openagent}"
OPENAGENT_MODEL="${OPENAGENT_MODEL:-qwen3:4b}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-32768}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-f16}"
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"

PIDS_LIMIT="${PIDS_LIMIT:-2048}"
HOST_MEM_BYTES="$(free -b | awk '/^Mem:/{print $2}')"
MEMORY_LIMIT="${MEMORY_LIMIT:-$(((HOST_MEM_BYTES - 1073741824) / 1048576))m}"

# Print the resolved configuration and stop, without building or running.
if [[ -n "${OPENAGENT_DRY_RUN:-}" ]]; then
    for var in HOST OPENAGENT_MODEL OLLAMA_CONTEXT_LENGTH OLLAMA_KV_CACHE_TYPE \
        OLLAMA_KEEP_ALIVE OLLAMA_DIR; do
        printf '%s=%s\n' "${var}" "${!var}"
    done
    printf 'HOST_DOCKER_ARGS=%s\nOLLAMA_DOCKER_ARGS=%s\n' \
        "${HOST_DOCKER_ARGS[*]}" "${OLLAMA_DOCKER_ARGS[*]}"
    exit 0
fi

# Docker has no notion of .gitignore; derive the .dockerignore from git so the
# two cannot drift.
{
    printf '.git\n'
    git -C "${SCRIPT_DIR}" ls-files --others --ignored --exclude-standard \
        --directory 2>/dev/null || true
} >"${SCRIPT_DIR}/.dockerignore"

OLLAMA_IMAGE="openagent-ollama:local"
IMAGE="${IMAGE:-openagent:local}"
docker build -q -t "${OLLAMA_IMAGE}" -f "${SCRIPT_DIR}/Dockerfile.ollama" "${SCRIPT_DIR}" >/dev/null
docker build \
    --build-arg "CONTAINER_USER=${CONTAINER_USER}" \
    --build-arg "CONTAINER_GROUP=${CONTAINER_GROUP}" \
    --build-arg "UID=${CONTAINER_UID}" \
    --build-arg "GID=${CONTAINER_GID}" \
    --build-arg "DOCKER_GID=${DOCKER_GID}" \
    --build-arg "HOME_DIR=${HOME}" \
    -t "${IMAGE}" -f "${SCRIPT_DIR}/Dockerfile.opencode" "${SCRIPT_DIR}"

docker network inspect "${NETWORK}" >/dev/null 2>&1 ||
    docker network create "${NETWORK}" >/dev/null

# Group-writable and setgid, so weights pulled by one identity stay usable by
# the other. Failure is ignored: it means the directory belongs to the other
# identity, which already set it.
mkdir -p "${OLLAMA_DIR}/models"
chgrp "${CONTAINER_GROUP}" "${OLLAMA_DIR}" "${OLLAMA_DIR}/models" 2>/dev/null || true
chmod g+ws "${OLLAMA_DIR}" "${OLLAMA_DIR}/models" 2>/dev/null || true

# Several hosts serve from the one models directory, so no server may prune
# blobs it does not recognise: they may be another host's download in flight.
OLLAMA_RUN_ARGS=(
    --network "${NETWORK}"
    --restart unless-stopped
    -v "${OLLAMA_DIR}:${OLLAMA_DIR}"
    -e "HOME=${OLLAMA_DIR}"
    -e "OLLAMA_MODELS=${OLLAMA_DIR}/models"
    -e OLLAMA_HOST=0.0.0.0:11434
    -e OLLAMA_NOPRUNE=1
    -e OLLAMA_NO_CLOUD=1
    -e OLLAMA_FLASH_ATTENTION=1
    -e "OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
    -e "OLLAMA_KV_CACHE_TYPE=${OLLAMA_KV_CACHE_TYPE}"
    -e "OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
    "${OLLAMA_DOCKER_ARGS[@]}"
)
# Debugging aid: the server keeps every inference request body under its /tmp.
[[ -n "${OLLAMA_DEBUG_LOG_REQUESTS:-}" ]] &&
    OLLAMA_RUN_ARGS+=(-e "OLLAMA_DEBUG_LOG_REQUESTS=${OLLAMA_DEBUG_LOG_REQUESTS}")

# The server is shared, so it is replaced only when what it would be started
# with has changed: the image or any of its run arguments. The spec is stored
# as a label and compared, rather than recreating on every run and cutting off
# the host's other sessions. The identity it runs as is left out: either one
# writes the store group-writable, so which of them started it is immaterial.
SPEC="$(printf '%s\n' "$(docker image inspect -f '{{.Id}}' "${OLLAMA_IMAGE}")" \
    "${OLLAMA_RUN_ARGS[@]}" | sha256sum | cut -c1-64)"
RUNNING="$(docker inspect -f '{{.State.Running}} {{index .Config.Labels "openagent.spec"}}' \
    "${OLLAMA_NAME}" 2>/dev/null || true)"
if [[ "${RUNNING}" != "true ${SPEC}" ]]; then
    if [[ -n "${RUNNING}" ]]; then
        echo ">> replacing ${OLLAMA_NAME}" >&2
        docker rm -f "${OLLAMA_NAME}" >/dev/null
    fi
    docker run -d --name "${OLLAMA_NAME}" --label "openagent.spec=${SPEC}" \
        --user "${CONTAINER_UID}:${CONTAINER_GID}" \
        "${OLLAMA_RUN_ARGS[@]}" "${OLLAMA_IMAGE}" >/dev/null
fi

for _ in $(seq 60); do
    docker exec "${OLLAMA_NAME}" ollama list >/dev/null 2>&1 && break
    sleep 1
done
docker exec "${OLLAMA_NAME}" ollama list >/dev/null

# Pulls serialise on a lock in the shared directory, so hosts starting together
# download a model once between them; the check repeats under the lock because
# the winner populates the store while the others wait.
if ! docker exec "${OLLAMA_NAME}" ollama show "${OPENAGENT_MODEL}" >/dev/null 2>&1; then
    LOCK="${OLLAMA_DIR}/.pull.lock"
    [[ -f "${LOCK}" ]] || install -m 0664 /dev/null "${LOCK}"
    (
        flock 9
        if ! docker exec "${OLLAMA_NAME}" ollama show "${OPENAGENT_MODEL}" >/dev/null 2>&1; then
            TTY=()
            [[ -t 1 ]] && TTY=(-t)
            docker exec "${TTY[@]}" "${OLLAMA_NAME}" ollama pull "${OPENAGENT_MODEL}"
        fi
    ) 9>"${LOCK}"
fi

# Host-backed /tmp, one directory per session name, emptied here so a session
# never inherits the previous one's scratch. The venv the entrypoint keeps in
# it is the one exception, so installed packages survive restarts.
TMP_DIR="${SCRATCH}/tmp/${NAME}"
mkdir -p "${TMP_DIR}"
find "${TMP_DIR}" -mindepth 1 -maxdepth 1 ! -name venv -exec rm -rf {} +

# Optional host state, mounted only where it exists: docker would otherwise
# materialise a missing source as a root-owned directory on the host.
MOUNTS=()
mount_if() {
    [[ -e "$1" ]] && MOUNTS+=(-v "$1:$1${2:+:$2}")
    return 0
}
mount_if "${SCRATCH}"
mount_if /etc/pip.conf ro
mount_if /etc/apt/apt.conf ro
mount_if "${HOME}/.gitconfig" ro
mount_if "${HOME}/.config/gh"
if [[ -d "${HOME}/.ssh" ]]; then
    # ~/.ssh stays read-only; ssh records new host keys in a writable directory
    # beside it (see the image's ssh_config).
    install -d -m 0700 "${HOME}/.ssh/known_hosts.d"
    mount_if "${HOME}/.ssh" ro
    mount_if "${HOME}/.ssh/known_hosts.d"
fi
while IFS= read -r -d '' path; do
    mount_if "${path}" ro
done < <(find /etc/apt/apt.conf.d -maxdepth 1 -iname '*proxy*' -print0 2>/dev/null)

TTY=(-i)
[[ -t 0 ]] && TTY=(-it)

exec docker run --rm "${TTY[@]}" \
    --name "${NAME}" \
    --init \
    --network "${NETWORK}" \
    --pids-limit "${PIDS_LIMIT}" \
    --memory "${MEMORY_LIMIT}" \
    "${HOST_DOCKER_ARGS[@]}" \
    -e "OLLAMA_HOST=http://${OLLAMA_NAME}:11434" \
    -e "OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}" \
    -e "OPENAGENT_MODEL=${OPENAGENT_MODEL}" \
    -e GH_TOKEN \
    -v "${TMP_DIR}:/tmp" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "${MOUNTS[@]}" \
    -v "$(pwd):$(pwd)" \
    -w "$(pwd)" \
    "${IMAGE}" "$@"
