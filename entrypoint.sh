#!/usr/bin/env bash
# Generate the opencode config from what the Ollama server currently holds,
# then hand over to opencode.
set -euo pipefail

# opencode is exec'd directly rather than from a login shell, so the image's
# profile.d umask never runs.
umask 002

# A venv with the numeric stack, kept in the host-backed /tmp that run.sh
# empties of everything else, and activated so opencode's shell commands use
# it. It is recreated whenever its interpreter does not run (first start, a
# half-written venv, a base image whose python moved), and the packages are
# installed only when one fails to import. setuptools and wheel are explicit
# because python3.12's ensurepip supplies neither.
VENV=/tmp/venv
if ! "${VENV}/bin/python" -c '' 2>/dev/null; then
    python3 -m venv --clear "${VENV}"
fi
# shellcheck disable=SC1091
source "${VENV}/bin/activate"
if ! python -c 'import numpy, scipy, sklearn, setuptools, wheel' 2>/dev/null; then
    pip install --progress-bar on setuptools wheel numpy scipy scikit-learn
fi

CONFIG="${HOME}/.config/opencode/opencode.json"
opencode-config > "${CONFIG}"
if ! jq -e '.model' "${CONFIG}" >/dev/null; then
    echo "!! ${OPENAGENT_MODEL} is not a tool-capable model on ${OLLAMA_HOST}" >&2
    exit 1
fi

exec opencode "$@"
