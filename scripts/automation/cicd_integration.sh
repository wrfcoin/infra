#!/bin/bash
# WRFCoin CI/CD Codebase Analysis Integration
# Runs during CI/CD pipeline to validate codebase integrity

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "$REPO_ROOT"

echo "🏭 Starting CI/CD codebase analysis..."

# Check if this is a merge/pull request
if [ "$CI_COMMIT_REF_NAME" = "main" ] || [ "$GITHUB_REF" = "refs/heads/main" ]; then
    echo "🎯 Main branch detected - running full analysis"
    FULL_ANALYSIS=true
else
    echo "🔀 Feature branch detected - running incremental analysis"
    FULL_ANALYSIS=false
fi

# Always update file manifest for changed files
echo "📁 Analyzing changed files..."
python3 scripts/generate_file_manifest.py

# Check domain categorization compliance
echo "🏗️ Validating domain categorization..."
python3 scripts/categorize_files_by_domain.py --validate-only

# Analyze dependency changes
if [ "$FULL_ANALYSIS" = true ]; then
    echo "🔗 Full dependency analysis..."
    python3 scripts/analyze_dependencies.py
else
    echo "🔗 Incremental dependency check..."
    python3 scripts/analyze_dependencies.py --changed-files-only
fi

# Validate CODEOWNERS coverage
echo "👥 Validating CODEOWNERS coverage..."
python3 scripts/generate_responsibility_matrix.py --validate-coverage

# Generate analysis report for CI
echo "📊 Generating CI analysis report..."
cat > codebase_analysis_report.md << EOF
# Codebase Analysis Report

**Pipeline:** \${CI_PIPELINE_ID:-unknown}
**Commit:** \${CI_COMMIT_SHA:-unknown}
**Branch:** \${CI_COMMIT_REF_NAME:-unknown}
**Timestamp:** $(date)

## Analysis Results
- ✅ File manifest updated
- ✅ Domain categorization validated
- ✅ Dependency analysis completed
- ✅ CODEOWNERS coverage validated

## Next Steps
- Review any new files for proper categorization
- Ensure new dependencies are documented
- Update team assignments if needed
EOF

echo "✅ CI/CD analysis completed"
