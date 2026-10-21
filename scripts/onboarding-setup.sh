#!/bin/bash
# WRFCoin Platform Automated Onboarding Setup Script
# This script automates the initial setup process for new developers

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ONBOARDING_LOG="$PROJECT_ROOT/.onboarding.log"
PROGRESS_FILE="$PROJECT_ROOT/.onboarding-progress.json"

# Default values
ROLE=""
EXPERIENCE_LEVEL=""
SKIP_INTERACTIVE=false
FORCE_REINSTALL=false
DRY_RUN=false

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$ONBOARDING_LOG"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$ONBOARDING_LOG"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$ONBOARDING_LOG"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$ONBOARDING_LOG"
}

# Progress tracking
init_progress() {
    cat > "$PROGRESS_FILE" << EOF
{
  "onboarding_id": "$(uuidgen 2>/dev/null || date +%s)",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "role": "$ROLE",
  "experience_level": "$EXPERIENCE_LEVEL",
  "steps": {
    "system_check": {"status": "pending", "started_at": null, "completed_at": null},
    "dependencies": {"status": "pending", "started_at": null, "completed_at": null},
    "environment": {"status": "pending", "started_at": null, "completed_at": null},
    "docker_setup": {"status": "pending", "started_at": null, "completed_at": null},
    "database_setup": {"status": "pending", "started_at": null, "completed_at": null},
    "verification": {"status": "pending", "started_at": null, "completed_at": null},
    "role_specific": {"status": "pending", "started_at": null, "completed_at": null}
  },
  "errors": [],
  "completed_at": null
}
EOF
}

update_progress() {
    local step=$1
    local status=$2
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    if command -v jq >/dev/null 2>&1; then
        jq ".steps.${step}.status = \"${status}\" | 
            .steps.${step}.${status}_at = \"${timestamp}\"" "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" &&
        mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
    fi
}

# Help function
show_help() {
    cat << EOF
WRFCoin Platform Onboarding Setup Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --role ROLE              Set development role (frontend, backend, blockchain, fullstack, devops, data)
    --experience LEVEL       Set experience level (beginner, intermediate, advanced)
    --skip-interactive       Skip interactive prompts (use defaults)
    --force-reinstall        Force reinstallation of dependencies
    --dry-run               Show what would be done without executing
    --help                  Show this help message

EXAMPLES:
    $0                                    # Interactive setup
    $0 --role frontend                    # Frontend developer setup
    $0 --role backend --experience advanced  # Advanced backend setup
    $0 --dry-run                         # Preview setup steps

ROLES:
    frontend     React/TypeScript frontend development
    backend      Node.js/TypeScript backend services
    blockchain   Rust blockchain core development
    fullstack    Full-stack development (frontend + backend)
    devops       Infrastructure and deployment
    data         Data science and analytics

EXPERIENCE LEVELS:
    beginner     New to the platform (detailed guidance)
    intermediate Standard setup with explanations
    advanced     Minimal prompts, faster setup
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --role)
                ROLE="$2"
                shift 2
                ;;
            --experience)
                EXPERIENCE_LEVEL="$2"
                shift 2
                ;;
            --skip-interactive)
                SKIP_INTERACTIVE=true
                shift
                ;;
            --force-reinstall)
                FORCE_REINSTALL=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Interactive role selection
select_role() {
    if [[ -n "$ROLE" ]]; then
        return
    fi

    echo -e "${BLUE}🎯 Select your development role:${NC}"
    echo "1) Frontend Developer (React/TypeScript)"
    echo "2) Backend Developer (Node.js/TypeScript)"
    echo "3) Blockchain Developer (Rust)"
    echo "4) Full-Stack Developer"
    echo "5) DevOps Engineer"
    echo "6) Data Scientist"
    
    read -p "Enter your choice (1-6): " choice
    
    case $choice in
        1) ROLE="frontend" ;;
        2) ROLE="backend" ;;
        3) ROLE="blockchain" ;;
        4) ROLE="fullstack" ;;
        5) ROLE="devops" ;;
        6) ROLE="data" ;;
        *) 
            log_error "Invalid choice. Please run the script again."
            exit 1
            ;;
    esac
}

# Interactive experience level selection
select_experience() {
    if [[ -n "$EXPERIENCE_LEVEL" ]]; then
        return
    fi

    echo -e "${BLUE}📚 Select your experience level:${NC}"
    echo "1) Beginner (New to the platform)"
    echo "2) Intermediate (Some experience with similar platforms)"
    echo "3) Advanced (Experienced developer, minimal guidance needed)"
    
    read -p "Enter your choice (1-3): " choice
    
    case $choice in
        1) EXPERIENCE_LEVEL="beginner" ;;
        2) EXPERIENCE_LEVEL="intermediate" ;;
        3) EXPERIENCE_LEVEL="advanced" ;;
        *) 
            log_error "Invalid choice. Please run the script again."
            exit 1
            ;;
    esac
}

# System requirements check
check_system_requirements() {
    log_info "Checking system requirements..."
    update_progress "system_check" "started"
    
    local errors=0
    
    # Check OS
    case "$(uname -s)" in
        Linux*)     OS="Linux" ;;
        Darwin*)    OS="macOS" ;;
        CYGWIN*|MINGW*|MSYS*) OS="Windows" ;;
        *)          OS="Unknown" ;;
    esac
    
    log_info "Operating System: $OS"
    
    # Check memory
    if [[ "$OS" == "Linux" ]]; then
        MEM_GB=$(free -g | awk '/^Mem:/{print $2}')
    elif [[ "$OS" == "macOS" ]]; then
        MEM_GB=$(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024))
    fi
    
    if [[ -n "$MEM_GB" ]]; then
        log_info "Available RAM: ${MEM_GB}GB"
        if [[ $MEM_GB -lt 8 ]]; then
            log_warning "Recommended: 16GB RAM for optimal development experience"
            ((errors++))
        elif [[ $MEM_GB -lt 16 ]]; then
            log_warning "16GB+ RAM recommended for better performance"
        fi
    fi
    
    # Check disk space
    DISK_AVAIL=$(df -h "$PROJECT_ROOT" | tail -1 | awk '{print $4}' | sed 's/G.*//')
    if [[ -n "$DISK_AVAIL" && "$DISK_AVAIL" -lt 50 ]]; then
        log_warning "Low disk space. 100GB+ recommended for development"
        ((errors++))
    fi
    
    if [[ $errors -eq 0 ]]; then
        update_progress "system_check" "completed"
        log_success "System requirements check passed"
    else
        update_progress "system_check" "failed"
        log_warning "System requirements check completed with warnings"
    fi
}

# Check and install dependencies
check_dependencies() {
    log_info "Checking required dependencies..."
    update_progress "dependencies" "started"
    
    local missing_deps=()
    
    # Node.js
    if command -v node >/dev/null 2>&1; then
        NODE_VERSION=$(node --version | cut -d'v' -f2)
        MAJOR_VERSION=$(echo "$NODE_VERSION" | cut -d'.' -f1)
        if [[ $MAJOR_VERSION -ge 20 ]]; then
            log_success "Node.js $NODE_VERSION (✓)"
        else
            log_warning "Node.js $NODE_VERSION found, but 20+ recommended"
            missing_deps+=("node20+")
        fi
    else
        log_error "Node.js not found"
        missing_deps+=("nodejs")
    fi
    
    # npm
    if command -v npm >/dev/null 2>&1; then
        NPM_VERSION=$(npm --version)
        log_success "npm $NPM_VERSION (✓)"
    else
        log_error "npm not found"
        missing_deps+=("npm")
    fi
    
    # Docker
    if command -v docker >/dev/null 2>&1; then
        if docker --version >/dev/null 2>&1; then
            DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
            log_success "Docker $DOCKER_VERSION (✓)"
        else
            log_warning "Docker found but not running"
            missing_deps+=("docker-running")
        fi
    else
        log_error "Docker not found"
        missing_deps+=("docker")
    fi
    
    # Docker Compose
    if command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then
        log_success "Docker Compose (✓)"
    else
        log_error "Docker Compose not found"
        missing_deps+=("docker-compose")
    fi
    
    # Git
    if command -v git >/dev/null 2>&1; then
        GIT_VERSION=$(git --version | cut -d' ' -f3)
        log_success "Git $GIT_VERSION (✓)"
    else
        log_error "Git not found"
        missing_deps+=("git")
    fi
    
    # Rust (for blockchain role)
    if [[ "$ROLE" == "blockchain" || "$ROLE" == "fullstack" ]]; then
        if command -v rustc >/dev/null 2>&1; then
            RUST_VERSION=$(rustc --version | cut -d' ' -f2)
            log_success "Rust $RUST_VERSION (✓)"
        else
            log_error "Rust not found (required for blockchain development)"
            missing_deps+=("rust")
        fi
    fi
    
    # Provide installation instructions for missing dependencies
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        show_installation_instructions "${missing_deps[@]}"
        update_progress "dependencies" "failed"
        return 1
    else
        update_progress "dependencies" "completed"
        log_success "All required dependencies found"
        return 0
    fi
}

# Show installation instructions for missing dependencies
show_installation_instructions() {
    local deps=("$@")
    
    echo -e "${YELLOW}🔧 Installation Instructions:${NC}"
    
    for dep in "${deps[@]}"; do
        case $dep in
            nodejs|node20+)
                echo -e "${BLUE}Node.js 20+:${NC}"
                if [[ "$OS" == "macOS" ]]; then
                    echo "  brew install node@20"
                elif [[ "$OS" == "Linux" ]]; then
                    echo "  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -"
                    echo "  sudo apt-get install -y nodejs"
                else
                    echo "  Download from: https://nodejs.org/en/download/"
                fi
                ;;
            docker)
                echo -e "${BLUE}Docker:${NC}"
                if [[ "$OS" == "macOS" ]]; then
                    echo "  Download Docker Desktop: https://www.docker.com/products/docker-desktop"
                elif [[ "$OS" == "Linux" ]]; then
                    echo "  curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh"
                else
                    echo "  Download Docker Desktop: https://www.docker.com/products/docker-desktop"
                fi
                ;;
            rust)
                echo -e "${BLUE}Rust:${NC}"
                echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
                echo "  source ~/.cargo/env"
                ;;
        esac
        echo
    done
    
    echo -e "${YELLOW}After installing missing dependencies, please run this script again.${NC}"
}

# Set up environment variables
setup_environment() {
    log_info "Setting up environment variables..."
    update_progress "environment" "started"
    
    local env_file="$PROJECT_ROOT/.env"
    local env_example="$PROJECT_ROOT/.env.example"
    
    if [[ ! -f "$env_file" ]]; then
        if [[ -f "$env_example" ]]; then
            cp "$env_example" "$env_file"
            log_success "Created .env file from .env.example"
        else
            # Generate secure secrets — abort if openssl is unavailable
            local jwt_secret
            jwt_secret=$(openssl rand -base64 32) || {
                log_error "openssl is required to generate JWT_SECRET. Install openssl and try again."
                update_progress "environment" "failed"
                exit 1
            }

            local db_password
            db_password=$(openssl rand -base64 24) || {
                log_error "openssl is required to generate DB password. Install openssl and try again."
                update_progress "environment" "failed"
                exit 1
            }

            # Create .env file with generated secrets
            cat > "$env_file" << EOF
# WRFCoin Platform Environment Configuration
NODE_ENV=development
PORT=4001
API_PORT=4001

# Database Configuration
# Password was auto-generated by onboarding-setup.sh.
# Make sure your local PostgreSQL uses this same password.
DATABASE_URL=postgresql://postgres:${db_password}@localhost:5432/wrfcoin
REDIS_URL=redis://localhost:6379

# JWT Configuration
JWT_SECRET=${jwt_secret}

# API Keys (Add your keys here)
# ANTHROPIC_API_KEY=your_anthropic_key
# PERPLEXITY_API_KEY=your_perplexity_key
# OPENAI_API_KEY=your_openai_key

# Development Configuration
LOG_LEVEL=debug
ENABLE_CORS=true
EOF
            log_success "Created .env file with auto-generated secrets"
        fi
    else
        log_info ".env file already exists"
    fi

    # Validate no placeholder or weak secrets remain
    if grep -qE '(your-jwt-secret-here|password@localhost)' "$env_file"; then
        log_error ".env contains insecure placeholder values. Please set real secrets before running services."
        update_progress "environment" "failed"
        exit 1
    fi

    update_progress "environment" "completed"
}

# Setup Docker environment
setup_docker() {
    log_info "Setting up Docker environment..."
    update_progress "docker_setup" "started"
    
    cd "$PROJECT_ROOT"
    
    # Pull required images
    log_info "Pulling Docker images..."
    if [[ "$DRY_RUN" == "false" ]]; then
        docker-compose pull postgres redis || {
            log_error "Failed to pull Docker images"
            update_progress "docker_setup" "failed"
            return 1
        }
    fi
    
    # Start core services
    log_info "Starting core services..."
    if [[ "$DRY_RUN" == "false" ]]; then
        docker-compose up -d postgres redis || {
            log_error "Failed to start core services"
            update_progress "docker_setup" "failed"
            return 1
        }
        
        # Wait for services to be ready
        log_info "Waiting for services to be ready..."
        sleep 10
        
        # Check if services are running
        if docker-compose ps | grep -q "Up"; then
            log_success "Core services started successfully"
        else
            log_error "Some services failed to start"
            docker-compose logs
            update_progress "docker_setup" "failed"
            return 1
        fi
    fi
    
    update_progress "docker_setup" "completed"
}

# Setup database
setup_database() {
    log_info "Setting up database..."
    update_progress "database_setup" "started"
    
    cd "$PROJECT_ROOT"
    
    # Install dependencies if not already done
    if [[ ! -d "node_modules" ]]; then
        log_info "Installing npm dependencies..."
        if [[ "$DRY_RUN" == "false" ]]; then
            npm install || {
                log_error "Failed to install npm dependencies"
                update_progress "database_setup" "failed"
                return 1
            }
        fi
    fi
    
    # Wait for PostgreSQL to be ready
    if [[ "$DRY_RUN" == "false" ]]; then
        log_info "Waiting for PostgreSQL to be ready..."
        timeout=60
        counter=0
        while ! docker-compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1; do
            if [[ $counter -ge $timeout ]]; then
                log_error "PostgreSQL failed to start within $timeout seconds"
                update_progress "database_setup" "failed"
                return 1
            fi
            sleep 1
            ((counter++))
        done
        
        # Run database migrations
        log_info "Running database migrations..."
        npm run db:migrate || {
            log_error "Database migrations failed"
            update_progress "database_setup" "failed"
            return 1
        }
        
        # Seed database (for development)
        if [[ "$EXPERIENCE_LEVEL" == "beginner" ]]; then
            log_info "Seeding database with sample data..."
            npm run db:seed || {
                log_warning "Database seeding failed (non-critical)"
            }
        fi
    fi
    
    update_progress "database_setup" "completed"
    log_success "Database setup completed"
}

# Verification tests
run_verification() {
    log_info "Running verification tests..."
    update_progress "verification" "started"
    
    cd "$PROJECT_ROOT"
    
    local verification_errors=0
    
    # Test database connection
    if [[ "$DRY_RUN" == "false" ]]; then
        log_info "Testing database connection..."
        if npm run db:connect >/dev/null 2>&1; then
            log_success "Database connection: ✓"
        else
            log_error "Database connection: ✗"
            ((verification_errors++))
        fi
        
        # Test Redis connection
        log_info "Testing Redis connection..."
        if docker-compose exec -T redis redis-cli ping | grep -q "PONG"; then
            log_success "Redis connection: ✓"
        else
            log_error "Redis connection: ✗"
            ((verification_errors++))
        fi
        
        # Test API health
        log_info "Starting API server for health check..."
        npm run dev:api &
        API_PID=$!
        sleep 15
        
        if curl -f http://localhost:4001/health >/dev/null 2>&1; then
            log_success "API health check: ✓"
        else
            log_error "API health check: ✗"
            ((verification_errors++))
        fi
        
        # Stop API server
        kill $API_PID 2>/dev/null || true
        
        # Run basic tests
        if [[ "$EXPERIENCE_LEVEL" != "beginner" ]]; then
            log_info "Running basic tests..."
            if npm test -- --passWithNoTests >/dev/null 2>&1; then
                log_success "Basic tests: ✓"
            else
                log_warning "Basic tests: Some tests failed (check later)"
            fi
        fi
    fi
    
    if [[ $verification_errors -eq 0 ]]; then
        update_progress "verification" "completed"
        log_success "All verification tests passed"
        return 0
    else
        update_progress "verification" "failed"
        log_error "$verification_errors verification tests failed"
        return 1
    fi
}

# Role-specific setup
setup_role_specific() {
    log_info "Setting up role-specific environment for: $ROLE"
    update_progress "role_specific" "started"
    
    case $ROLE in
        frontend)
            setup_frontend_role
            ;;
        backend)
            setup_backend_role
            ;;
        blockchain)
            setup_blockchain_role
            ;;
        fullstack)
            setup_frontend_role
            setup_backend_role
            ;;
        devops)
            setup_devops_role
            ;;
        data)
            setup_data_role
            ;;
        *)
            log_warning "Unknown role: $ROLE. Skipping role-specific setup."
            ;;
    esac
    
    update_progress "role_specific" "completed"
}

# Frontend-specific setup
setup_frontend_role() {
    log_info "Setting up frontend development environment..."
    
    # Install frontend dependencies
    if [[ -d "$PROJECT_ROOT/frontend" && "$DRY_RUN" == "false" ]]; then
        cd "$PROJECT_ROOT/frontend"
        npm install || log_warning "Frontend dependencies installation failed"
    fi
    
    # Install recommended VS Code extensions
    if command -v code >/dev/null 2>&1 && [[ "$DRY_RUN" == "false" ]]; then
        log_info "Installing recommended VS Code extensions..."
        code --install-extension ms-vscode.vscode-typescript-next
        code --install-extension bradlc.vscode-tailwindcss
        code --install-extension ms-playwright.playwright
    fi
    
    log_success "Frontend environment setup completed"
}

# Backend-specific setup
setup_backend_role() {
    log_info "Setting up backend development environment..."
    
    # Install backend dependencies
    if [[ -d "$PROJECT_ROOT/backend" && "$DRY_RUN" == "false" ]]; then
        cd "$PROJECT_ROOT/backend"
        npm install || log_warning "Backend dependencies installation failed"
    fi
    
    log_success "Backend environment setup completed"
}

# Blockchain-specific setup
setup_blockchain_role() {
    log_info "Setting up blockchain development environment..."
    
    # Install Rust components
    if command -v rustup >/dev/null 2>&1 && [[ "$DRY_RUN" == "false" ]]; then
        rustup component add clippy rustfmt
        rustup target add wasm32-unknown-unknown
    fi
    
    # Build blockchain core
    if [[ -d "$PROJECT_ROOT/blockchain-core" && "$DRY_RUN" == "false" ]]; then
        cd "$PROJECT_ROOT/blockchain-core"
        cargo build || log_warning "Blockchain core build failed"
    fi
    
    log_success "Blockchain environment setup completed"
}

# DevOps-specific setup
setup_devops_role() {
    log_info "Setting up DevOps environment..."
    
    # Install additional tools if available
    if [[ "$DRY_RUN" == "false" ]]; then
        # Check for kubectl, terraform, etc.
        command -v kubectl >/dev/null && log_success "kubectl found"
        command -v terraform >/dev/null && log_success "terraform found"
    fi
    
    log_success "DevOps environment setup completed"
}

# Data science-specific setup
setup_data_role() {
    log_info "Setting up data science environment..."
    
    # Check for Python and data science tools
    if command -v python3 >/dev/null 2>&1; then
        log_success "Python 3 found"
    else
        log_warning "Python 3 not found (may be needed for data analysis)"
    fi
    
    log_success "Data science environment setup completed"
}

# Generate completion report
generate_completion_report() {
    local completion_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Update progress file
    if command -v jq >/dev/null 2>&1; then
        jq ".completed_at = \"$completion_time\"" "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" &&
        mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
    fi
    
    echo
    echo -e "${GREEN}🎉 Onboarding Setup Complete!${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    echo -e "${GREEN}✓${NC} Role: $ROLE"
    echo -e "${GREEN}✓${NC} Experience Level: $EXPERIENCE_LEVEL"
    echo -e "${GREEN}✓${NC} System Requirements Checked"
    echo -e "${GREEN}✓${NC} Dependencies Installed"
    echo -e "${GREEN}✓${NC} Environment Configured"
    echo -e "${GREEN}✓${NC} Docker Services Running"
    echo -e "${GREEN}✓${NC} Database Setup Complete"
    echo -e "${GREEN}✓${NC} Verification Tests Passed"
    echo -e "${GREEN}✓${NC} Role-Specific Setup Complete"
    echo
    echo -e "${BLUE}Next Steps:${NC}"
    echo "1. Read the role-specific onboarding guide:"
    echo "   📖 docs/onboarding/roles/${ROLE}-developer.md"
    echo
    echo "2. Start development:"
    case $ROLE in
        frontend)
            echo "   🚀 npm run dev:frontend"
            echo "   📚 npm run storybook"
            ;;
        backend)
            echo "   🚀 npm run dev:api"
            echo "   🧪 npm run test:backend"
            ;;
        blockchain)
            echo "   🚀 cd blockchain-core && cargo run"
            echo "   🧪 cd blockchain-core && cargo test"
            ;;
        fullstack)
            echo "   🚀 npm run dev"
            echo "   🧪 npm test"
            ;;
    esac
    echo
    echo "3. Join the community:"
    echo "   💬 Discord: https://discord.gg/wrfcoin-${ROLE}"
    echo "   📝 GitHub: https://github.com/wrfcoin/platform"
    echo
    echo "4. Make your first contribution:"
    echo "   🎯 Pick a 'good first issue' from GitHub"
    echo "   📋 Follow the contribution guidelines"
    echo
    echo -e "${YELLOW}Troubleshooting:${NC}"
    echo "• If you encounter issues: docs/troubleshooting/README.md"
    echo "• For help: #onboarding channel on Discord"
    echo "• Log file: $ONBOARDING_LOG"
    echo "• Progress file: $PROGRESS_FILE"
    echo
    echo -e "${GREEN}Happy coding! 🚀${NC}"
}

# Cleanup function
cleanup() {
    if [[ -n "$API_PID" ]]; then
        kill $API_PID 2>/dev/null || true
    fi
}

# Main execution
main() {
    trap cleanup EXIT
    
    echo -e "${BLUE}🚀 WRFCoin Platform Onboarding Setup${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo
    
    # Initialize log
    echo "$(date): Starting WRFCoin onboarding setup" > "$ONBOARDING_LOG"
    
    # Parse arguments
    parse_args "$@"
    
    # Interactive prompts if not skipped
    if [[ "$SKIP_INTERACTIVE" == "false" ]]; then
        select_role
        select_experience
    fi
    
    # Validate required parameters
    if [[ -z "$ROLE" ]]; then
        log_error "Role not specified. Use --role or run interactively."
        exit 1
    fi
    
    if [[ -z "$EXPERIENCE_LEVEL" ]]; then
        EXPERIENCE_LEVEL="intermediate"  # Default
    fi
    
    # Show dry run message
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}🔍 DRY RUN MODE - No changes will be made${NC}"
        echo
    fi
    
    # Initialize progress tracking
    init_progress
    
    # Execute setup steps
    log_info "Starting onboarding setup for $ROLE developer ($EXPERIENCE_LEVEL level)"
    
    check_system_requirements || true  # Don't exit on warnings
    
    if ! check_dependencies; then
        log_error "Please install missing dependencies and run the script again."
        exit 1
    fi
    
    setup_environment
    setup_docker || exit 1
    setup_database || exit 1
    run_verification || exit 1
    setup_role_specific
    
    # Generate completion report
    generate_completion_report
    
    log_success "Onboarding setup completed successfully!"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi