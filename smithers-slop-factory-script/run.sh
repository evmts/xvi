#!/usr/bin/env bash
# Run the Guillotine build workflow
# Usage: ./run.sh [target]
# Example: ./run.sh effect

set -euo pipefail

TARGET="${1:-zig}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$SCRIPT_DIR"

# Force CLI agent for all workflow tasks
export USE_CLI_AGENTS=1

# ANTHROPIC_API_KEY must be set in the environment for Claude CLI to work

# Show engine errors instead of swallowing them
export SMITHERS_DEBUG=1

# Target-specific DB isolation
export WORKFLOW_TARGET="$TARGET"

SMITHERS_CLI="$SCRIPT_DIR/node_modules/smithers/src/cli/index.ts"
if [[ -f "$HOME/smithers/src/cli/index.ts" ]]; then
  SMITHERS_CLI="$HOME/smithers/src/cli/index.ts"
fi

if [[ ! -f "$SMITHERS_CLI" ]]; then
  echo "error: smithers CLI not found at $SMITHERS_CLI"
  exit 1
fi

echo "Starting Guillotine build workflow — Target: $TARGET"
echo "Root directory: $ROOT_DIR"
echo "Press Ctrl+C to stop."
echo ""

bun run "$SMITHERS_CLI" run workflow.tsx --input "{\"target\": \"$TARGET\"}" --root-dir "$ROOT_DIR"
