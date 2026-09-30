#!/usr/bin/env bash
# hovercraft: RTX 5090 (32GB). Sourced by run.sh; see hosts/defroster.sh.
OLLAMA_DOCKER_ARGS+=(--gpus all)
