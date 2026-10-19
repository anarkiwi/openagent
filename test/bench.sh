#!/usr/bin/env bash
# Measure how each model fits and runs on the Ollama server container named
# by OLLAMA_NAME (default openagent-ollama) on the local docker host.
#
#   test/bench.sh qwen3.8:27b@262144 qwen3.6:35b-a3b@131072 ...
#
# Each argument is a model and the context it is loaded with. The prompt is
# this repository's run.sh and docs, so prefill is measured over a realistic
# agent-sized input. One tab-separated line per model: total resident size,
# the share of it in VRAM, prefill and decode rates in tokens per second.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLLAMA_NAME="${OLLAMA_NAME:-openagent-ollama}"
NUM_PREDICT="${NUM_PREDICT:-512}"
PROMPT="$(cat "${ROOT}/run.sh" "${ROOT}"/docs/*.md)
Summarise the above."

api() {
    docker run --rm -i --network "container:${OLLAMA_NAME}" curlimages/curl:8.17.0 \
        -fsS "http://localhost:11434/api/$1" ${2:+-d @-}
}

printf 'model\tctx\tsize_gb\tvram_pct\tprefill_tps\tdecode_tps\n'
for spec in "$@"; do
    model="${spec%@*}"
    ctx="${spec#*@}"
    [[ "${ctx}" == "${spec}" ]] && ctx=32768
    echo ">> ${model} @ ${ctx}" >&2
    # Unload everything first, so each model is placed on an empty GPU.
    api ps | jq -c '.models[] | {model: .name, keep_alive: 0}' |
        while read -r req; do api generate - <<<"${req}" >/dev/null; done
    gen="$(jq -nc --arg m "${model}" --arg p "${PROMPT}" --argjson c "${ctx}" \
        --argjson n "${NUM_PREDICT}" \
        '{model: $m, prompt: $p, stream: false,
          options: {num_ctx: $c, num_predict: $n, temperature: 0}}' | api generate -)"
    ps="$(api ps | jq -c --arg m "${model}" '.models[] | select(.name == $m)')"
    jq -nr --arg m "${model}" --argjson c "${ctx}" --argjson g "${gen}" --argjson p "${ps}" \
        '[$m, $c, ($p.size / 1e9 * 10 | round / 10),
          ($p.size_vram / $p.size * 100 | round),
          ($g.prompt_eval_count / $g.prompt_eval_duration * 1e9 | round),
          ($g.eval_count / $g.eval_duration * 1e9 | round)] | @tsv'
done
