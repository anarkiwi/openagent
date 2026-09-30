#!/usr/bin/env bash
# defroster: RTX 5080 (16GB). Sourced by run.sh.
#
# Only the server needs the GPU. --gpus needs nvidia-container-toolkit on the
# host, not an "nvidia" docker runtime; the Ollama image ships its own CUDA
# runtime libraries, so no CUDA base image is needed either.
OLLAMA_DOCKER_ARGS+=(--gpus all)
