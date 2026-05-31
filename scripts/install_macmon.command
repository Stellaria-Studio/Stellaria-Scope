#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install Homebrew first from https://brew.sh/ or skip this optional backend."
  exit 1
fi
brew install macmon
cat <<'EOF'

macmon installed. Restart StellarScope Advanced Helper to let v8 merge CPU/GPU temperature data.
EOF
