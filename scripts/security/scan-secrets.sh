#!/usr/bin/env bash
# Never print matches. Scan the index for hooks and commit history for CI.
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v gitleaks >/dev/null || { echo 'Install the pinned Gitleaks version from scripts/security/tools.json.' >&2; exit 1; }
case "${1:-history}" in
  staged) gitleaks git --pre-commit --staged --redact=100 --no-banner --config .gitleaks.toml . ;;
  history) gitleaks git --redact=100 --no-banner --config .gitleaks.toml . ;;
  range) : "${ALBUS_SCAN_RANGE:?commit range required}"; gitleaks git --log-opts="$ALBUS_SCAN_RANGE" --redact=100 --no-banner --config .gitleaks.toml . ;;
  *) echo 'Expected staged, history or range.' >&2; exit 2 ;;
esac
