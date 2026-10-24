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
tool-capable model the server holds is offered in opencode; a model's vision projector and
speculative-decoding draft are dropped unless `OPENAGENT_VISION` or
`OPENAGENT_DRAFT` is set. Host extras such as
`--gpus` are opt-in via `hosts/<hostname>.sh`.

## Guards

`hooks/` holds the PreToolUse guards ported from the `claude` image and the
opencode plugin (`guards.js`) that runs them before each tool call; a denial
aborts the call with its reason. Run their tests with
`cd hooks && pytest -n auto && node --test`.

| Guard | Blocks |
| --- | --- |
| `format_check.py` | `git commit` whose content fails `black` (Python) or `clang-format` (C/C++) |
| `durable_comments.py` | `git commit` whose comments carry a measurement, a date or a change story |
| `worktree_guard.py` | `git worktree add`/`move` outside the session's repo |
| `min_comments.py` | Python `write`/`edit` with verbose docstrings or stacked comments |

See [docs/container.md](docs/container.md) and [docs/hooks.md](docs/hooks.md).
