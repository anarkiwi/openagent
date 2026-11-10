#!/usr/bin/env bash
# defroster: RTX 5080. Sourced by run.sh.
#
# Only the server needs the GPU. --gpus needs nvidia-container-toolkit on the
# host, not an "nvidia" docker runtime; the Ollama image ships its own CUDA
# runtime libraries, so no CUDA base image is needed either.
#
# The same qwen3.8 27B as hovercraft (see hosts/hovercraft.sh), trading speed
# for quality: its weights alone outgrow the 5080, so Ollama keeps the remaining
# layers in host memory. Every layer and KV cache slot that spills runs on
# the CPU, so the window is half the trained one, which keeps about half the
# model on the GPU; test/bench.sh shows the split and rates for others.
OPENAGENT_MODEL="${OPENAGENT_MODEL:-qwen3.8:27b}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-131072}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
OPENAGENT_OUTPUT_LIMIT="${OPENAGENT_OUTPUT_LIMIT:-32768}"
OPENAGENT_THINK="${OPENAGENT_THINK:-xhigh}"
OLLAMA_DOCKER_ARGS+=(--gpus all)
