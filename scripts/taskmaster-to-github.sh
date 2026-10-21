#!/bin/bash

# Task Master to GitHub Issue Converter
# Usage: ./taskmaster-to-github.sh <task_id>

TASK_ID=$1

if [ -z "$TASK_ID" ]; then
    echo "Usage: $0 <task_id>"
    echo "Example: $0 69"
    exit 1
fi

echo "Converting Task Master task $TASK_ID to GitHub issue..."

# Get task data from Task Master
TASK_DATA=$(npx task-master-ai get-task --id="$TASK_ID" --project-root="$(pwd)" --format=json)

if [ $? -ne 0 ]; then
    echo "Error: Could not retrieve task $TASK_ID from Task Master"
    exit 1
fi

# Extract key fields (you'd parse JSON properly in a real script)
TITLE=$(echo "$TASK_DATA" | jq -r '.data.title')
DESCRIPTION=$(echo "$TASK_DATA" | jq -r '.data.description')
DETAILS=$(echo "$TASK_DATA" | jq -r '.data.details')
PRIORITY=$(echo "$TASK_DATA" | jq -r '.data.priority')
STATUS=$(echo "$TASK_DATA" | jq -r '.data.status')
COMPLEXITY=$(echo "$TASK_DATA" | jq -r '.data.complexityScore')

# Create GitHub issue body
ISSUE_BODY="## Overview
$DESCRIPTION

## Task Details from Task Master
- **Task ID**: $TASK_ID
- **Priority**: $PRIORITY
- **Status**: $STATUS
- **Complexity Score**: $COMPLEXITY/10

## Implementation Details
$DETAILS

## Success Criteria
- [ ] Task implementation completed
- [ ] Tests passing
- [ ] Documentation updated

---
*Converted from Task Master task $TASK_ID*"

# Determine priority label
case $PRIORITY in
    "high") PRIORITY_LABEL="high-priority" ;;
    "medium") PRIORITY_LABEL="medium-priority" ;;
    "low") PRIORITY_LABEL="low-priority" ;;
    *) PRIORITY_LABEL="priority-$PRIORITY" ;;
esac

# Create GitHub issue
ISSUE_URL=$(gh issue create \
    --title "[$PRIORITY] $TITLE" \
    --body "$ISSUE_BODY" \
    --assignee "@me")

if [ $? -eq 0 ]; then
    echo "✅ Successfully created GitHub issue: $ISSUE_URL"
    echo "📝 Task Master task $TASK_ID converted to GitHub issue"
    
    # Optionally update Task Master with GitHub issue link
    echo "🔗 You can add this GitHub issue URL to the task details in Task Master"
else
    echo "❌ Failed to create GitHub issue"
    exit 1
fi