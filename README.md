# openagent

Containerized [opencode](https://opencode.ai) sessions backed by a local
[Ollama](https://ollama.com) server.

## Use

    ./run.sh                  # build, start the host's Ollama server, open the opencode TUI
    ./run.sh run "<prompt>"   # any opencode args replace the TUI
    OPENAGENT_MODEL=qwen3:8b ./run.sh

Must be run as one of the shared `claude`, `ansible` or `openagent` identities. One Ollama server
container (`openagent-ollama`) runs per host and is shared by every session on
it; weights live under `/scratch/ollama`, shared by every host. The session
model (`OPENAGENT_MODEL`, default `qwen3:4b`, overridable per host) is pulled on first use, and every
tool-capable model the server holds is offered in opencode. Host extras such as
`--gpus` are opt-in via `hosts/<hostname>.sh`.

See [docs/container.md](docs/container.md).
