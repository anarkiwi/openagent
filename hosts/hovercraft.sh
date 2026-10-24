#!/usr/bin/env bash
# hovercraft: RTX 5090. Sourced by run.sh; see hosts/defroster.sh.
#
# qwen3.8 attends fully in only one layer in four, so with a q8_0 KV cache its
# full trained 256K window costs no more than 128K at f16, and fits beside the
# 27B dense weights. The tag's default sampling is the one Qwen evaluates
# agentic coding with.
OPENAGENT_MODEL="${OPENAGENT_MODEL:-qwen3.8:27b}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-262144}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
OLLAMA_DOCKER_ARGS+=(--gpus all)
OPENAGENT_OUTPUT_LIMIT="${OPENAGENT_OUTPUT_LIMIT:-32768}"
OPENAGENT_THINK="${OPENAGENT_THINK:-xhigh}"
