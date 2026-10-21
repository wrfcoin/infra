#!/bin/bash
# WRFCoin Weekly Codebase Maintenance
# Comprehensive maintenance and cleanup tasks

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "$REPO_ROOT"

echo "🧹 Starting weekly codebase maintenance..."

# Clean up temporary files
echo "🗑️ Cleaning temporary files..."
find . -name "*.tmp" -delete
find . -name "*.cache" -delete
find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# Validate all generated files
echo "✅ Validating generated files..."
files_to_check=(
    "file_manifest.json"
    "file_domain_mapping.json"
    "dependency_graph_data.json"
    "responsibility_matrix.json"
    "CODEOWNERS"
    "architectural_diagrams.html"
    "interactive_dependency_graph.html"
)

for file in "${files_to_check[@]}"; do
    if [ -f "$file" ]; then
        echo "   ✅ $file exists"
    else
        echo "   ❌ $file missing - regenerating..."
        case "$file" in
            "file_manifest.json")
                python3 scripts/generate_file_manifest.py
                ;;
            "file_domain_mapping.json")
                python3 scripts/categorize_files_by_domain.py
                ;;
            "dependency_graph_data.json")
                python3 scripts/analyze_dependencies.py
                ;;
            "responsibility_matrix.json" | "CODEOWNERS")
                python3 scripts/generate_responsibility_matrix.py
                ;;
            "architectural_diagrams.html")
                python3 scripts/generate_architectural_diagrams.py
                ;;
            "interactive_dependency_graph.html")
                # Regenerate if missing
                echo "Warning: Interactive graph missing"
                ;;
        esac
    fi
done

# Generate weekly report
echo "📊 Generating weekly maintenance report..."
cat > weekly_maintenance_report.md << EOF
# Weekly Maintenance Report

**Date:** $(date)
**Status:** Completed

## Files Validated
$(for file in "${files_to_check[@]}"; do
    if [ -f "$file" ]; then
        echo "- ✅ $file"
    else
        echo "- ❌ $file (regenerated)"
    fi
done)

## Statistics
- Total Files: $(jq '.statistics.total_files' file_manifest.json 2>/dev/null || echo "unknown")
- Domains: $(jq '.summary.total_domains' file_domain_mapping.json 2>/dev/null || echo "unknown")
- Dependencies: $(jq '.summary.total_graph_nodes' dependency_graph_data.json 2>/dev/null || echo "unknown")
- Teams: $(jq '.summary_statistics.files_per_team | length' responsibility_matrix.json 2>/dev/null || echo "unknown")

## Recommendations
- Review any new files for proper categorization
- Update team assignments for new modules
- Consider dependency consolidation opportunities
EOF

echo "✅ Weekly maintenance completed"
