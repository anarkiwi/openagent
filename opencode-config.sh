#!/usr/bin/env bash
# Print an opencode config exposing every tool-capable model the Ollama server
# at OLLAMA_HOST has pulled, with OPENAGENT_MODEL as the default.
#
# Each model's context limit is the smaller of its trained context and the
# server's OLLAMA_CONTEXT_LENGTH, since the server truncates any prompt past
# the latter. OPENAGENT_OUTPUT_LIMIT, or a quarter of the context if smaller,
# is reserved for output: opencode compacts once prompt plus reserved output
# would exceed the limit, which keeps a request inside the window the server
# will actually evaluate.
#
# A thinking model's earlier reasoning is sent back in each assistant message's
# "reasoning" field, the only one Ollama's /v1 endpoint reads, so a template
# that keeps the thinking of the current agent turn renders it instead of an
# empty think block.
#
# A model that names its thinking levels gets one variant per level and
# OPENAGENT_THINK as its default effort where it is one of them, sent as
# reasoning_effort; the server silently ignores a level the model lacks.
#
# A model with the vision capability takes image attachments, which the /v1
# endpoint accepts as image_url parts.
set -euo pipefail

: "${OLLAMA_HOST:?}" "${OLLAMA_CONTEXT_LENGTH:?}" "${OPENAGENT_MODEL:?}"
: "${OPENAGENT_OUTPUT_LIMIT:?}" "${OPENAGENT_THINK:?}"
BASE="${OLLAMA_HOST%/}"

curl -fsS "${BASE}/api/tags" | jq -r '.models[].name' |
    while read -r model; do
        jq -nc --arg m "${model}" '{model: $m}' |
            curl -fsS "${BASE}/api/show" -d @- |
            jq -c --arg m "${model}" '{
                name: $m,
                caps: (.capabilities // []),
                levels: [.thinking.values // [] | .[] | strings],
                ctx: ([.model_info // {} | to_entries[]
                       | select(.key | endswith(".context_length")) | .value][0])
            }'
    done |
    jq -s --arg base "${BASE}" --arg default "${OPENAGENT_MODEL}" \
        --argjson num_ctx "${OLLAMA_CONTEXT_LENGTH}" \
        --argjson out "${OPENAGENT_OUTPUT_LIMIT}" --arg effort "${OPENAGENT_THINK}" '
        map(select(.caps | index("tools"))
            | ([.ctx // $num_ctx, $num_ctx] | min) as $c
            | (.caps | index("thinking") != null) as $think
            | (.caps | index("vision") != null) as $vision
            | {key: .name, value: ({
                name: .name,
                tool_call: true,
                reasoning: $think,
                limit: {context: $c, output: ([$out, $c / 4] | min | floor)}}
                + if $think then {interleaved: {field: "reasoning"}} else {} end
                + if $think and (.levels | length) > 0 then {
                    variants: ([.levels[] | {key: ., value: {reasoningEffort: .}}]
                        | from_entries)}
                    + if .levels | index($effort) then
                        {options: {reasoningEffort: $effort}} else {} end
                  else {} end
                + if $vision then {attachment: true,
                    modalities: {input: ["text", "image"], output: ["text"]}}
                  else {} end)})
        | from_entries as $models
        | {
            "$schema": "https://opencode.ai/config.json",
            autoupdate: false,
            share: "disabled",
            provider: {ollama: {
                npm: "@ai-sdk/openai-compatible",
                name: "Ollama",
                options: {baseURL: ($base + "/v1")},
                models: $models}}
          }
        + if $models[$default] then {model: ("ollama/" + $default)} else {} end'
