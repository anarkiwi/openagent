#!/usr/bin/env bash
# hovercraft: RTX 5090 (32GB). Sourced by run.sh; see hosts/defroster.sh.
#
# qwen3.6 attends fully in only one layer in four, so with a q8_0 KV cache its
# full trained 256K window costs no more than 128K at f16, and fits beside the
# 27B dense weights. The -coding tag is the same weights with Qwen's coding
# sampling defaults.
OPENAGENT_MODEL="${OPENAGENT_MODEL:-qwen3.6:27b-coding}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-262144}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
OLLAMA_DOCKER_ARGS+=(--gpus all)
