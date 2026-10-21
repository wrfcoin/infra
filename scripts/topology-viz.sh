#!/usr/bin/env bash
# topology-viz.sh — Docker Compose network topology auto-visualizer
#
# Parses docker-compose*.yml files and emits a Mermaid or DOT diagram showing
# service nodes, depends_on edges, and exposed port annotations.
#
# Usage:
#   ./topology-viz.sh [--dir <path>] [--format mermaid|dot] [--output <file>]
#
# Options:
#   --dir <path>    Directory to search for docker-compose*.yml files.
#                   Defaults to the infra repo root (parent of this script's directory).
#   --format        Output format: 'mermaid' (default) or 'dot'
#   --output <file> Write output to file instead of stdout
#
# Requirements:
#   - python3 (with PyYAML: pip install pyyaml) — preferred
#   - OR yq (https://github.com/mikefarah/yq) as fallback
#
# Examples:
#   ./topology-viz.sh
#   ./topology-viz.sh --dir <repo-root>/testnet --format dot
#   ./topology-viz.sh --format mermaid --output topology.md

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Default search dir: parent of scripts/ (repo root)
DEFAULT_DIR="$(dirname "$SCRIPT_DIR")"

SEARCH_DIR="$DEFAULT_DIR"
FORMAT="mermaid"
OUTPUT_FILE=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      SEARCH_DIR="$2"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '/^# /p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--dir <path>] [--format mermaid|dot] [--output <file>]" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ "$FORMAT" != "mermaid" && "$FORMAT" != "dot" ]]; then
  echo "ERROR: --format must be 'mermaid' or 'dot'" >&2
  exit 1
fi

if [[ ! -d "$SEARCH_DIR" ]]; then
  echo "ERROR: Directory not found: $SEARCH_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Detect parser (python3 + PyYAML preferred, yq fallback)
# ---------------------------------------------------------------------------
USE_PYTHON=false
USE_YQ=false

if command -v python3 &>/dev/null; then
  if python3 -c "import yaml" 2>/dev/null; then
    USE_PYTHON=true
  fi
fi

if [[ "$USE_PYTHON" == "false" ]]; then
  if command -v yq &>/dev/null; then
    USE_YQ=true
  else
    echo "ERROR: Neither python3+PyYAML nor yq found." >&2
    echo "  Install PyYAML: pip install pyyaml" >&2
    echo "  Install yq:     https://github.com/mikefarah/yq" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Find compose files
# ---------------------------------------------------------------------------
mapfile -t COMPOSE_FILES < <(find "$SEARCH_DIR" -name "docker-compose*.yml" -type f | sort)

if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
  echo "ERROR: No docker-compose*.yml files found under: $SEARCH_DIR" >&2
  exit 1
fi

echo "# Found ${#COMPOSE_FILES[@]} compose file(s):" >&2
for f in "${COMPOSE_FILES[@]}"; do
  echo "#   $f" >&2
done
echo "" >&2

# ---------------------------------------------------------------------------
# Python-based YAML parser — extracts services, depends_on, networks, ports
# ---------------------------------------------------------------------------
PYTHON_PARSER='
import sys
import json
import os

try:
    import yaml
except ImportError:
    sys.exit("PyYAML not installed: pip install pyyaml")

files = sys.argv[1:]
services = {}   # name -> { depends_on: [], ports: [], networks: [] }

for fpath in files:
    try:
        with open(fpath) as f:
            doc = yaml.safe_load(f)
    except Exception as e:
        print(f"WARN: skipping {fpath}: {e}", file=sys.stderr)
        continue

    if not isinstance(doc, dict):
        continue
    svc_block = doc.get("services") or {}
    if not isinstance(svc_block, dict):
        continue

    for svc_name, svc_cfg in svc_block.items():
        if svc_name not in services:
            services[svc_name] = {"depends_on": [], "ports": [], "networks": []}

        if not isinstance(svc_cfg, dict):
            continue

        # depends_on: list or dict (condition syntax)
        dep = svc_cfg.get("depends_on", [])
        if isinstance(dep, dict):
            dep = list(dep.keys())
        elif isinstance(dep, str):
            dep = [dep]
        for d in dep:
            if d not in services[svc_name]["depends_on"]:
                services[svc_name]["depends_on"].append(d)

        # ports: short or long syntax
        raw_ports = svc_cfg.get("ports", [])
        for p in raw_ports:
            if isinstance(p, dict):
                # long syntax: {target: ..., published: ...}
                pub = p.get("published") or p.get("target") or ""
                services[svc_name]["ports"].append(str(pub))
            elif isinstance(p, str):
                # short syntax: "host:container" or just "container"
                parts = p.split(":")
                services[svc_name]["ports"].append(parts[0])
            elif isinstance(p, int):
                services[svc_name]["ports"].append(str(p))

        # networks
        nets = svc_cfg.get("networks", {})
        if isinstance(nets, list):
            for n in nets:
                if n not in services[svc_name]["networks"]:
                    services[svc_name]["networks"].append(n)
        elif isinstance(nets, dict):
            for n in nets.keys():
                if n not in services[svc_name]["networks"]:
                    services[svc_name]["networks"].append(n)

    # Deduplicate ports per service
    for svc_name in services:
        seen = []
        for p in services[svc_name]["ports"]:
            if p not in seen:
                seen.append(p)
        services[svc_name]["ports"] = seen

print(json.dumps(services))
'

# ---------------------------------------------------------------------------
# yq-based fallback — simpler, limited to basic depends_on + ports
# ---------------------------------------------------------------------------
yq_parse() {
  local fpath="$1"
  # Returns JSON in same schema as Python parser (best effort)
  yq eval -o=json '.services // {}' "$fpath" 2>/dev/null || echo '{}'
}

# ---------------------------------------------------------------------------
# Collect service data
# ---------------------------------------------------------------------------
if [[ "$USE_PYTHON" == "true" ]]; then
  RAW_JSON=$(python3 -c "$PYTHON_PARSER" "${COMPOSE_FILES[@]}")
else
  # Merge all compose files via yq and parse
  MERGED_JSON="{}"
  for f in "${COMPOSE_FILES[@]}"; do
    FILE_JSON=$(yq_parse "$f")
    MERGED_JSON=$(python3 -c "
import json, sys
a = json.loads(sys.argv[1])
b = json.loads(sys.argv[2])
for k, v in b.items():
    if k not in a:
        a[k] = v
print(json.dumps(a))
" "$MERGED_JSON" "$FILE_JSON")
  done

  # Normalize yq output to expected schema
  RAW_JSON=$(python3 -c "
import json, sys
raw = json.loads(sys.argv[1])
out = {}
for name, cfg in raw.items():
    if not isinstance(cfg, dict):
        cfg = {}
    dep = cfg.get('depends_on', [])
    if isinstance(dep, dict):
        dep = list(dep.keys())
    elif isinstance(dep, str):
        dep = [dep]
    raw_ports = cfg.get('ports', [])
    ports = []
    for p in raw_ports:
        if isinstance(p, dict):
            ports.append(str(p.get('published') or p.get('target') or ''))
        elif isinstance(p, (str, int)):
            ports.append(str(p).split(':')[0])
    nets = cfg.get('networks', {})
    if isinstance(nets, dict):
        nets = list(nets.keys())
    elif not isinstance(nets, list):
        nets = []
    out[name] = {'depends_on': dep, 'ports': ports, 'networks': nets}
print(json.dumps(out))
" "$MERGED_JSON")
fi

# ---------------------------------------------------------------------------
# Sanitize service names for diagram node IDs (strip non-alphanumeric/dash)
# ---------------------------------------------------------------------------
sanitize_id() {
  # Replace hyphens and underscores with underscores; strip other special chars
  echo "$1" | tr '-' '_' | tr -cd '[:alnum:]_'
}

# ---------------------------------------------------------------------------
# Build diagram from JSON
# ---------------------------------------------------------------------------
build_mermaid() {
  python3 - "$RAW_JSON" <<'PYEOF'
import json, sys, re

data = json.loads(sys.argv[1])

def sanitize(name):
    return re.sub(r'[^a-zA-Z0-9_]', '_', name.replace('-', '_'))

lines = ["graph LR"]

# Emit nodes with port labels
for svc, info in sorted(data.items()):
    node_id = sanitize(svc)
    ports = info.get("ports", [])
    # Filter empty port strings
    ports = [p for p in ports if p]
    if ports:
        port_str = "\\n" + "\\n".join(f":{p}" for p in ports[:4])  # cap at 4 ports for readability
        label = f'"{svc}{port_str}"'
    else:
        label = f'"{svc}"'
    lines.append(f'  {node_id}[{label}]')

# Emit dependency edges
for svc, info in sorted(data.items()):
    node_id = sanitize(svc)
    for dep in info.get("depends_on", []):
        dep_id = sanitize(dep)
        # Ensure dep node exists even if it came from a different compose file
        if dep not in data:
            lines.insert(1, f'  {dep_id}["{dep}"]')
        lines.append(f'  {node_id} -->|depends| {dep_id}')

print("\n".join(lines))
PYEOF
}

build_dot() {
  python3 - "$RAW_JSON" <<'PYEOF'
import json, sys, re

data = json.loads(sys.argv[1])

def sanitize(name):
    return re.sub(r'[^a-zA-Z0-9_]', '_', name.replace('-', '_'))

lines = [
    "digraph wrfcoin_topology {",
    "  rankdir=LR;",
    "  node [shape=box, style=filled, fillcolor=lightblue, fontname=Helvetica];",
    "  edge [fontname=Helvetica, fontsize=10];",
    ""
]

# Emit nodes
for svc, info in sorted(data.items()):
    node_id = sanitize(svc)
    ports = [p for p in info.get("ports", []) if p]
    if ports:
        port_str = "\\n".join(f":{p}" for p in ports[:4])
        label = f'{svc}\\n{port_str}'
    else:
        label = svc
    lines.append(f'  {node_id} [label="{label}"];')

lines.append("")

# Emit edges
for svc, info in sorted(data.items()):
    node_id = sanitize(svc)
    for dep in info.get("depends_on", []):
        dep_id = sanitize(dep)
        lines.append(f'  {node_id} -> {dep_id} [label="depends"];')

lines.append("}")
print("\n".join(lines))
PYEOF
}

# ---------------------------------------------------------------------------
# Emit output
# ---------------------------------------------------------------------------
case "$FORMAT" in
  mermaid) DIAGRAM=$(build_mermaid) ;;
  dot)     DIAGRAM=$(build_dot) ;;
esac

if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$DIAGRAM" > "$OUTPUT_FILE"
  echo "Written to: $OUTPUT_FILE" >&2
else
  echo "$DIAGRAM"
fi
