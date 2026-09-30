#!/usr/bin/env bash
# hovercraft: RTX 5090 (32GB). Sourced by run.sh; see hosts/defroster.sh.
#
# qwen3.6 attends fully in only one layer in four, so its KV cache is small
# enough for the 27B dense weights and a 128K window to share the card.
# The -coding tag is the same weights with Qwen's coding sampling defaults.
OPENAGENT_MODEL="${OPENAGENT_MODEL:-qwen3.6:27b-coding}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-131072}"
OLLAMA_DOCKER_ARGS+=(--gpus all)
