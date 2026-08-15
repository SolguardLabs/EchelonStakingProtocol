#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

required=(
    README.md
    SECURITY.md
    assets/banner.png
    docs/architecture.md
    docs/economic-model.md
    docs/governance-and-security.md
    docs/integration.md
    docs/operations.md
    docs/rewards-and-epochs.md
    docs/staking-lifecycle.md
)

for artifact in "${required[@]}"; do
    test -f "$artifact" || { echo "missing artifact: $artifact" >&2; exit 1; }
done

document_count="$(find docs -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')"
test "$document_count" = "7" || { echo "expected 7 documents, found $document_count" >&2; exit 1; }

banner_bytes="$(wc -c < assets/banner.png | tr -d ' ')"
test "$banner_bytes" -ge 100000 || { echo "banner is below the minimum size" >&2; exit 1; }

diagram_count="$(grep -Rho '```mermaid' README.md SECURITY.md docs | wc -l | tr -d ' ')"
test "$diagram_count" -ge 26 || { echo "expected at least 26 diagrams, found $diagram_count" >&2; exit 1; }

solidity_lines="$(find src -type f -name '*.sol' -exec awk 'NF { count++ } END { print count + 0 }' {} + | awk '{ total += $1 } END { print total + 0 }')"
test "$solidity_lines" -ge 3000 || { echo "contract surface is unexpectedly small" >&2; exit 1; }

# Keep the check deterministic on Windows worktrees where Git may expose CRLF
# despite an LF index. GitHub Actions runs the same rule on its native checkout.
git -c core.autocrlf=true diff --check
echo "repository artifacts ok: $document_count documents, $diagram_count diagrams, $solidity_lines Solidity lines"
