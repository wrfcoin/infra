#!/bin/bash

# Bulk Task Master to GitHub Issue Converter
# Usage: ./bulk-taskmaster-to-github.sh [task_ids...]
# Example: ./bulk-taskmaster-to-github.sh 69 70 71
# Or: ./bulk-taskmaster-to-github.sh --pending (converts all pending tasks)

PROJECT_ROOT="$(pwd)"

convert_task() {
    local task_id=$1
    echo "🔄 Converting Task Master task $task_id..."
    
    # Use the individual conversion script
    ./scripts/taskmaster-to-github.sh "$task_id"
    
    if [ $? -eq 0 ]; then
        echo "✅ Task $task_id converted successfully"
        return 0
    else
        echo "❌ Failed to convert task $task_id"
        return 1
    fi
}

if [ "$1" = "--pending" ]; then
    echo "🔍 Finding all pending tasks..."
    
    # Get all pending tasks from Task Master
    PENDING_TASKS=$(npx task-master-ai get-tasks --project-root="$PROJECT_ROOT" --status=pending --format=json | jq -r '.data[].id')
    
    if [ -z "$PENDING_TASKS" ]; then
        echo "ℹ️ No pending tasks found"
        exit 0
    fi
    
    echo "📋 Found pending tasks: $PENDING_TASKS"
    
    for task_id in $PENDING_TASKS; do
        convert_task "$task_id"
        sleep 2  # Rate limiting to avoid API issues
    done
    
elif [ "$1" = "--high-priority" ]; then
    echo "🔍 Finding all high priority tasks..."
    
    # Get all high priority tasks from Task Master  
    HIGH_PRIORITY_TASKS=$(npx task-master-ai get-tasks --project-root="$PROJECT_ROOT" --format=json | jq -r '.data[] | select(.priority == "high") | .id')
    
    for task_id in $HIGH_PRIORITY_TASKS; do
        convert_task "$task_id"
        sleep 2
    done
    
elif [ $# -eq 0 ]; then
    echo "Usage: $0 [task_ids...] | --pending | --high-priority"
    echo "Examples:"
    echo "  $0 69 70 71                # Convert specific tasks"
    echo "  $0 --pending              # Convert all pending tasks"
    echo "  $0 --high-priority        # Convert all high priority tasks"
    exit 1
    
else
    # Convert specific task IDs
    echo "🔄 Converting specified tasks: $@"
    
    success_count=0
    total_count=$#
    
    for task_id in "$@"; do
        if convert_task "$task_id"; then
            ((success_count++))
        fi
        sleep 2  # Rate limiting
    done
    
    echo "📊 Conversion complete: $success_count/$total_count tasks converted successfully"
fi