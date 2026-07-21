#!/usr/bin/env bash
# Configure or remove Tekton MCP server for Cursor and Claude Code.
# Both tools read from .claude/settings.json (single config).
# Reads KUBECONFIG from the active oc context or prompts the user.
#
# Usage:
#   ./scripts/hack/configure-mcp.sh           # auto-detect kubeconfig
#   ./scripts/hack/configure-mcp.sh ~/.kube/my-cluster  # explicit kubeconfig
#   ./scripts/hack/configure-mcp.sh --remove   # remove MCP config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MCP_CONFIG="$REPO_ROOT/.claude/settings.json"

die() { echo "ERROR: $*" >&2; exit 1; }

# Find tekton-mcp-server binary
MCP_BIN=$(command -v tekton-mcp-server 2>/dev/null || echo "")
if [[ -z "$MCP_BIN" ]]; then
  MCP_BIN="$(go env GOPATH 2>/dev/null)/bin/tekton-mcp-server"
  if [[ ! -x "$MCP_BIN" ]]; then
    echo "tekton-mcp-server not found. Installing..."
    go install github.com/tektoncd/mcp-server/cmd/tekton-mcp-server@latest
    MCP_BIN="$(go env GOPATH)/bin/tekton-mcp-server"
  fi
fi

remove_mcp() {
  if [[ -f "$MCP_CONFIG" ]]; then
    rm -f "$MCP_CONFIG"
    echo "Removed $MCP_CONFIG"
  fi
  echo "Tekton MCP server config removed."
}

configure_mcp() {
  local kubeconfig="$1"

  # Verify cluster is accessible
  if ! KUBECONFIG="$kubeconfig" oc whoami --show-server >/dev/null 2>&1; then
    echo "WARNING: Cannot connect to cluster via $kubeconfig"
    echo "The MCP server will use this kubeconfig but the cluster may not be reachable."
  else
    local server
    server=$(KUBECONFIG="$kubeconfig" oc whoami --show-server 2>/dev/null)
    echo "Cluster: $server"
    echo "User:    $(KUBECONFIG="$kubeconfig" oc whoami 2>/dev/null)"
  fi

  mkdir -p "$(dirname "$MCP_CONFIG")"

  cat > "$MCP_CONFIG" <<EOF
{
  "mcpServers": {
    "tekton": {
      "command": "$MCP_BIN",
      "env": {
        "KUBECONFIG": "$kubeconfig"
      }
    }
  }
}
EOF

  echo ""
  echo "============================================================"
  echo "  Tekton MCP server configured!"
  echo "============================================================"
  echo "  Config:     $MCP_CONFIG"
  echo "  KUBECONFIG: $kubeconfig"
  echo "  Binary:     $MCP_BIN"
  echo ""
  echo "  Both Cursor and Claude Code read from .claude/settings.json"
  echo ""
  echo "  >>> RESTART CURSOR / CLAUDE CODE to activate the MCP server <<<"
  echo ""
  echo "  After restart, try these prompts:"
  echo "    - \"List all pipeline runs in pipelines-ci\""
  echo "    - \"Show me the logs for the failed test\""
  echo "    - \"What's the status of the latest acceptance test?\""
  echo "============================================================"
}

# --- Main ---
case "${1:-}" in
  --remove|--clean|--destroy)
    remove_mcp
    ;;
  --help|-h)
    echo "Usage: $0 [kubeconfig-path | --remove]"
    echo "  No args:     auto-detect from current oc context or KUBECONFIG env"
    echo "  <path>:      use specified kubeconfig file"
    echo "  --remove:    remove MCP config (e.g., when cluster is destroyed)"
    ;;
  "")
    # Auto-detect kubeconfig
    if [[ -n "${KUBECONFIG:-}" && -f "$KUBECONFIG" ]]; then
      configure_mcp "$KUBECONFIG"
    elif oc whoami --show-server >/dev/null 2>&1; then
      # Use the kubeconfig that oc is currently using
      kc="${KUBECONFIG:-$HOME/.kube/config}"
      configure_mcp "$kc"
    else
      echo "No active cluster found."
      echo "Please provide a kubeconfig path:"
      echo "  $0 ~/.kube/my-cluster"
      echo ""
      echo "Or log in first:"
      echo "  oc login https://api.example.com:6443 -u kubeadmin -p <password>"
      echo "  $0"
      exit 1
    fi
    ;;
  *)
    # Explicit kubeconfig path
    [[ -f "$1" ]] || die "kubeconfig not found: $1"
    configure_mcp "$1"
    ;;
esac
