#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v forge >/dev/null 2>&1; then
    for foundry_dir in "$HOME/.foundry/bin" "${USERPROFILE:-}/.foundry/bin"; do
        if [ -x "$foundry_dir/forge" ] || [ -x "$foundry_dir/forge.exe" ]; then
            export PATH="$foundry_dir:$PATH"
            break
        fi
    done
fi

forge --version
forge fmt --check
forge build --sizes
FOUNDRY_PROFILE=ci forge test -vvv
