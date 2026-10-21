#!/bin/bash
# WRFCoin Technical Debt Analysis - Tmux Multi-Agent Launcher
# Launches 8 specialized Claude Code agents in parallel tmux sessions

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SESSION_NAME="wrfcoin-debt-analysis"
# Determine project root from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   WRFCoin Technical Debt Analysis - Multi-Agent Launcher      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if tmux is installed
if ! command -v tmux &> /dev/null; then
    echo -e "${RED}ERROR: tmux is not installed${NC}"
    echo "Install with: sudo apt-get install tmux"
    exit 1
fi

# Check if session already exists
if tmux has-session -t $SESSION_NAME 2>/dev/null; then
    echo -e "${YELLOW}Session '$SESSION_NAME' already exists!${NC}"
    read -p "Kill existing session and restart? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        tmux kill-session -t $SESSION_NAME
        echo -e "${GREEN}Killed existing session${NC}"
    else
        echo "Attaching to existing session..."
        tmux attach-session -t $SESSION_NAME
        exit 0
    fi
fi

# Create reports directory
mkdir -p "$PROJECT_ROOT/reports"

# Create new tmux session (detached)
echo -e "${GREEN}Creating tmux session: $SESSION_NAME${NC}"
tmux new-session -d -s $SESSION_NAME -n "code-analyzer" -c "$PROJECT_ROOT"

# Window 0: Code Analyzer
echo -e "${BLUE}[1/8] Setting up Code Analyzer agent...${NC}"
tmux send-keys -t $SESSION_NAME:0 "cd $PROJECT_ROOT" C-m
tmux send-keys -t $SESSION_NAME:0 "echo '=== CODE ANALYZER AGENT ===' && echo 'Run: npm run todo-report to start'" C-m
tmux send-keys -t $SESSION_NAME:0 "# Paste from AGENT_LAUNCH_GUIDE.md Terminal 1" C-m

# Window 1: Security Manager
echo -e "${BLUE}[2/8] Setting up Security Manager agent...${NC}"
tmux new-window -t $SESSION_NAME:1 -n "security-manager" -c "$PROJECT_ROOT"
tmux send-keys -t $SESSION_NAME:1 "cd $PROJECT_ROOT" C-m
tmux send-keys -t $SESSION_NAME:1 "echo '=== SECURITY MANAGER AGENT ===' && echo 'Run: npm audit --audit-level=moderate to start'" C-m
tmux send-keys -t $SESSION_NAME:1 "# Paste from AGENT_LAUNCH_GUIDE.md Terminal 2" C-m

# Window 2: Rust Core Dev
echo -e "${BLUE}[3/8] Setting up Rust Core Developer agent...${NC}"
tmux new-window -t $SESSION_NAME:2 -n "rust-core-dev" -c "$PROJECT_ROOT"
tmux send-keys -t $SESSION_NAME:2 "cd $PROJECT_ROOT" C-m
tmux send-keys -t $SESSION_NAME:2 "echo '=== RUST CORE DEVELOPER AGENT ===' && echo 'Run: cd blockchain-core && cargo check to start'" C-m
tmux send-keys -t $SESSION_NAME:2 "# Paste from AGENT_LAUNCH_GUIDE.md Terminal 3" C-m

# Window 3: Solidity Dev
echo -e "${BLUE}[4/8] Setting up Solidity Developer agent...${NC}"
tmux new-window -t $SESSION_NAME:3 -n "solidity-dev" -c "$PROJECT_ROOT"
tmux send-keys -t $SESSION_NAME:3 "cd $PROJECT_ROOT" C-m
tmux send-keys -t $SESSION_NAME:3 "echo '=== SOLIDITY DEVELOPER AGENT ===' && echo 'Run: npm run security:slither to start'" C-m
tmux send-keys -t $SESSION_NAME:3 "# Paste from AGENT_LAUNCH_GUIDE.md Terminal 4" C-m

# Window 4: Backend Dev
echo -e "${BLUE}[5/8] Setting up Backend Developer agent...${NC}"
tmux new-window -t $SESSION_NAME:4 -n "backend-dev" -c "$PROJECT_ROOT"
tmux send-keys -t $SESSION_NAME:4 "cd $PROJECT_ROOT" C-m
tmux send-keys -t $SESSION_NAME:4 "echo '=== BACKEND DEVELOPER AGENT ===' && echo 'Run: npm run test:graphql:performance to start'" C-m
tmux send-keys -t $SESSION_NAME:4 "# Paste from AGENT_LAUNCH_GUIDE.md Terminal 5" C-m

# Window 5: Frontend Dev
echo -e "${BLUE}[6/8] Setting up Frontend Developer agent...${NC}"
tmux new-window -t $SESSION_NAME:5 -n "frontend-dev" -c "$PROJECT_ROOT"
tmux send-keys -t $SESSION_NAME:5 "cd $PROJECT_ROOT" C-m
tmux send-keys -t $SESSION_NAME:5 "echo '=== FRONTEND DEVELOPER AGENT ===' && echo 'Run: cd frontend && npm run build to start'" C-m
tmux send-keys -t $SESSION_NAME:5 "# Paste from AGENT_LAUNCH_GUIDE.md Terminal 6" C-m

# Window 6: Tester
echo -e "${BLUE}[7/8] Setting up Test Quality Specialist agent...${NC}"
tmux new-window -t $SESSION_NAME:6 -n "tester" -c "$PROJECT_ROOT"
tmux send-keys -t $SESSION_NAME:6 "cd $PROJECT_ROOT" C-m
tmux send-keys -t $SESSION_NAME:6 "echo '=== TEST QUALITY SPECIALIST AGENT ===' && echo 'Run: npm run test:coverage to start'" C-m
tmux send-keys -t $SESSION_NAME:6 "# Paste from AGENT_LAUNCH_GUIDE.md Terminal 7" C-m

# Window 7: System Architect
echo -e "${BLUE}[8/8] Setting up System Architect agent...${NC}"
tmux new-window -t $SESSION_NAME:7 -n "system-architect" -c "$PROJECT_ROOT"
tmux send-keys -t $SESSION_NAME:7 "cd $PROJECT_ROOT" C-m
tmux send-keys -t $SESSION_NAME:7 "echo '=== SYSTEM ARCHITECT AGENT ===' && echo 'Analyze: infra/docker/ and infra/monitoring/'" C-m
tmux send-keys -t $SESSION_NAME:7 "# Paste from AGENT_LAUNCH_GUIDE.md Terminal 8" C-m

# Window 8: Progress Monitor (helpful dashboard)
echo -e "${BLUE}[BONUS] Setting up Progress Monitor...${NC}"
tmux new-window -t $SESSION_NAME:8 -n "monitor" -c "$PROJECT_ROOT"
tmux send-keys -t $SESSION_NAME:8 "cd $PROJECT_ROOT" C-m
tmux send-keys -t $SESSION_NAME:8 "cat << 'EOF'" C-m
tmux send-keys -t $SESSION_NAME:8 "╔════════════════════════════════════════════════════════════════╗" C-m
tmux send-keys -t $SESSION_NAME:8 "║        WRFCoin Technical Debt Analysis - Progress Monitor      ║" C-m
tmux send-keys -t $SESSION_NAME:8 "╚════════════════════════════════════════════════════════════════╝" C-m
tmux send-keys -t $SESSION_NAME:8 "" C-m
tmux send-keys -t $SESSION_NAME:8 "This window monitors all agent progress." C-m
tmux send-keys -t $SESSION_NAME:8 "" C-m
tmux send-keys -t $SESSION_NAME:8 "Quick commands:" C-m
tmux send-keys -t $SESSION_NAME:8 "  ls -lh reports/           # Check completed reports" C-m
tmux send-keys -t $SESSION_NAME:8 "  watch -n 30 'ls reports/' # Auto-refresh report list" C-m
tmux send-keys -t $SESSION_NAME:8 "  tail -f reports/*.md      # Live view of report updates" C-m
tmux send-keys -t $SESSION_NAME:8 "" C-m
tmux send-keys -t $SESSION_NAME:8 "Tmux navigation:" C-m
tmux send-keys -t $SESSION_NAME:8 "  Ctrl+b then 0-7           # Switch to agent windows" C-m
tmux send-keys -t $SESSION_NAME:8 "  Ctrl+b then 8             # Return to this monitor" C-m
tmux send-keys -t $SESSION_NAME:8 "  Ctrl+b then d             # Detach (agents keep running)" C-m
tmux send-keys -t $SESSION_NAME:8 "  Ctrl+b then [             # Scroll mode (q to exit)" C-m
tmux send-keys -t $SESSION_NAME:8 "" C-m
tmux send-keys -t $SESSION_NAME:8 "To reattach: tmux attach -t $SESSION_NAME" C-m
tmux send-keys -t $SESSION_NAME:8 "EOF" C-m
tmux send-keys -t $SESSION_NAME:8 "" C-m
tmux send-keys -t $SESSION_NAME:8 "echo 'Starting progress monitor...'" C-m
tmux send-keys -t $SESSION_NAME:8 "watch -n 30 'echo \"=== Analysis Progress ===\" && ls -lh reports/ 2>/dev/null || echo \"No reports yet\"'" C-m

# Select first window
tmux select-window -t $SESSION_NAME:0

echo ""
echo -e "${GREEN}✓ All agent windows created successfully!${NC}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}                    NEXT STEPS${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "1. Attach to the session:"
echo -e "   ${GREEN}tmux attach -t $SESSION_NAME${NC}"
echo ""
echo -e "2. Navigate between agent windows:"
echo -e "   ${BLUE}Ctrl+b then 0-7${NC} (agent windows)"
echo -e "   ${BLUE}Ctrl+b then 8${NC} (progress monitor)"
echo ""
echo -e "3. In each agent window, launch Claude Code:"
echo -e "   ${GREEN}claude${NC}"
echo ""
echo -e "4. Then paste the agent-specific prompt from:"
echo -e "   ${BLUE}AGENT_LAUNCH_GUIDE.md${NC}"
echo ""
echo -e "5. Monitor progress in window 8 or detach with:"
echo -e "   ${BLUE}Ctrl+b then d${NC}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Ready to begin analysis! 🚀${NC}"
echo ""

# Optionally attach automatically
read -p "Attach to session now? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    tmux attach-session -t $SESSION_NAME
fi
