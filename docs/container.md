# Container

`run.sh` builds two images and runs two kinds of container on the host whose
docker daemon it talks to.

| Container | Image | Lifetime |
| --- | --- | --- |
| `openagent-ollama` | `Dockerfile.ollama` | one per host, shared by all sessions, stopped when the last one exits |
| `openagent-<host>-<dir>` | `Dockerfile.opencode` | one per session, `--rm` |

They share the user-defined docker network `openagent`; the session reaches the
server as `http://openagent-ollama:11434` and the server publishes no host
port.

## Host

The host is the docker daemon's name (`docker info`, overridable with
`OPENAGENT_HOST`), not `hostname`, so a `run.sh` started inside another
container still picks up the right `hosts/<host>.sh`. That file is sourced
before `run.sh` applies its defaults, so it sets its own with `${VAR:-value}`
and the caller's environment still wins over both. It may also append flags to
`HOST_DOCKER_ARGS` (session) or `OLLAMA_DOCKER_ARGS`
(server). `hosts/defroster.sh` gives the server `--gpus all`;
`hosts/hovercraft.sh` does the same and raises the default model to
`qwen3.6:27b-coding` with its full 256K context and a `q8_0` KV cache, which
the 5090's 32GB holds because qwen3.6's KV cache covers only its
full-attention layers; the Ollama image
carries its own CUDA runtime, so only the host's `nvidia-container-toolkit` is
required.

## Ollama server

Runs as the invoking identity with `HOME` and `OLLAMA_MODELS` under
`/scratch/ollama` (`OLLAMA_DIR`), with umask `002` and a setgid, group-writable
store, so either identity can pull into it. Settings:

| Variable | Default | Notes |
| --- | --- | --- |
| `OLLAMA_CONTEXT_LENGTH` | `32768` | context the server evaluates; opencode's limits follow it |
| `OLLAMA_KEEP_ALIVE` | `30m` | how long an idle model stays loaded |
| `OLLAMA_NOPRUNE` | `1` | the store is shared across hosts, so a starting server must not delete blobs another host is still downloading |
| `OLLAMA_KV_CACHE_TYPE` | `f16` | `q8_0` halves the KV cache, for a longer context in the same memory |
| `OLLAMA_FLASH_ATTENTION` | `1` | required by a quantized KV cache |
| `OLLAMA_NO_CLOUD` | `1` | local models only |

The server is replaced only when its image or run arguments change: a hash of
both is stored in the `openagent.spec` label and compared on every run, so a
routine start never interrupts the host's other sessions, and a stopped server
with the same hash is restarted rather than recreated. The identity is not
part of the hash.

The server runs only while the host has sessions. When a session exits,
`run.sh` stops the server unless another session container on the `openagent`
network is created or running. Starting the server through to creating the
session container, and that check, hold `flock` on
`/scratch/ollama/.<server>-<host>.lock`, so a session still starting is never
missed. The server keeps `--restart unless-stopped`, so one that was running
when the host rebooted comes back and runs until the next session exits.

Model pulls take an `flock` on `/scratch/ollama/.pull.lock`, so hosts starting
together download a model once.

## opencode session

`opencode` is pinned in `package.json`/`package-lock.json` (tracked by
dependabot) and installed in a `node` build stage; only its standalone binary
reaches the runtime image.

At start the entrypoint runs `opencode-config`, which asks the server for its
models (`/api/tags`, `/api/show`) and writes `~/.config/opencode/opencode.json`
with an `@ai-sdk/openai-compatible` provider holding every model whose
capabilities include `tools`. Each model's context limit is the smaller of its
trained context and `OLLAMA_CONTEXT_LENGTH`, with a quarter reserved for output,
so opencode compacts before a request outgrows what the server evaluates.
Thinking models are marked `interleaved` with field `reasoning`: opencode
otherwise returns earlier reasoning as `reasoning_content`, which Ollama's `/v1`
endpoint ignores, so templates that keep the thinking of the current agent turn
(qwen3.5/3.6) would see every earlier step with an empty think block. The
session refuses to start if `OPENAGENT_MODEL` is not among them.

`AGENTS.md` is installed as opencode's global instructions.

The session runs as the invoking identity (UID, `sw` group, home path), which
must be one of `OPENAGENT_USERS` (default `claude ansible openagent`): accounts
with the same UID on every host and `sw` as primary group. It uses umask `002`
and mounts the working directory, `/scratch`, the docker socket
and, where present, `~/.gitconfig`, `~/.config/gh`, `~/.ssh` (read-only, with a
writable `known_hosts.d`), `/etc/pip.conf` and the apt proxy config.
`GH_TOKEN` is passed through when set, as it is for the `openagent` identity,
whose GitHub token comes from its shell environment rather than `gh` login
state. Its `/tmp`
is `/scratch/tmp/<name>`, emptied at start apart from `/tmp/venv`. Session
state is discarded on exit.

`/tmp/venv` is a venv the entrypoint activates before starting opencode, so
the agent's shell commands find `numpy`, `scipy`, `scikit-learn`, `setuptools`
and `wheel` already importable. It is created on a session name's first run,
recreated whenever its interpreter does not run, and topped up only when one
of those imports fails, so a warm start costs one interpreter launch. Packages
the agent installs into it persist across sessions. The image carries the
compilers and headers (`build-essential`, `python3-dev`, `pkg-config`,
`gfortran`) a source build needs.

## Test

`OPENAGENT_DRY_RUN=1 ./run.sh` prints the resolved settings and exits without
building or running anything. `test/hosts.sh` uses it to check that precedence
for the files in `hosts/`.

`OLLAMA_DEBUG_LOG_REQUESTS=1 ./run.sh` starts the server with Ollama's request
logging, which keeps every inference request body under the server
container's `/tmp/ollama-request-logs-*`; `docker cp` retrieves them once the
server has stopped.

`test/e2e.sh` runs `run.sh` against a small model on a CPU-only server under a
throwaway scratch directory, has it call a tool, checks the reply, and checks
from the logged requests that the reasoning behind the tool call was sent back
in the `reasoning` field, and checks that the server stopped when the session
exited; CI runs it on every push.
