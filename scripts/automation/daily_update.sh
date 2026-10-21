#!/bin/bash
# WRFCoin Codebase Daily Update Script
# Automated execution for continuous inventory maintenance

set -e

echo "🔄 Starting daily codebase inventory update..."
echo "Timestamp: $(date)"

# Navigate to project root
cd "$(dirname "$0")/../.."

# Update file manifest
echo "📁 Updating file manifest..."
python3 scripts/generate_file_manifest.py

# Update domain categorization
echo "🏗️ Updating domain categorization..."
python3 scripts/categorize_files_by_domain.py

# Update dependency analysis
echo "🔗 Updating dependency analysis..."
python3 scripts/analyze_dependencies.py

# Update responsibility matrix
echo "👥 Updating responsibility matrix..."
python3 scripts/generate_responsibility_matrix.py

# Update architectural diagrams
echo "📊 Updating architectural diagrams..."
python3 scripts/generate_architectural_diagrams.py

# Update unified dashboard
echo "🎯 Updating unified dashboard..."
python3 scripts/unified_codebase_integration_system.py

# Commit changes if any
if ! git diff --quiet; then
    echo "📝 Committing automated updates..."
    git add .
    git commit -m "chore: automated codebase inventory update

🤖 Generated with [Claude Code](https://claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>"
else
    echo "✅ No changes detected"
fi

echo "✅ Daily update completed successfully"
