#!/bin/bash

# WRFCoin Platform - MkDocs Architecture Handbook Builder
# This script builds the comprehensive architecture documentation using MkDocs

set -e

echo "🏗️  Building WRFCoin Platform Architecture Handbook..."

# Check if MkDocs is installed
if ! command -v mkdocs &> /dev/null; then
    echo "❌ MkDocs not found. Installing MkDocs and dependencies..."
    
    # Try to install using different methods
    if command -v pip3 &> /dev/null; then
        pip3 install mkdocs mkdocs-material mkdocs-mermaid2-plugin mkdocs-awesome-pages-plugin
    elif command -v pip &> /dev/null; then
        pip install mkdocs mkdocs-material mkdocs-mermaid2-plugin mkdocs-awesome-pages-plugin
    elif command -v python3 -m pip &> /dev/null; then
        python3 -m pip install mkdocs mkdocs-material mkdocs-mermaid2-plugin mkdocs-awesome-pages-plugin
    else
        echo "❌ Cannot install MkDocs. Please install Python pip first."
        echo "   On Ubuntu/Debian: sudo apt-get install python3-pip"
        echo "   On macOS: brew install python"
        echo "   On Windows: Download Python from python.org"
        exit 1
    fi
fi

# Verify MkDocs installation
if ! command -v mkdocs &> /dev/null; then
    echo "❌ MkDocs installation failed or not in PATH"
    exit 1
fi

echo "✅ MkDocs found: $(mkdocs --version)"

# Create output directory
mkdir -p docs/generated/handbook

# Check if mkdocs.yml exists
if [ ! -f "mkdocs.yml" ]; then
    echo "❌ mkdocs.yml not found in project root"
    exit 1
fi

echo "📚 Building documentation..."

# Build the documentation
if mkdocs build --site-dir docs/generated/handbook --clean; then
    echo "✅ Architecture handbook built successfully!"
    echo "📖 Documentation available at: docs/generated/handbook/index.html"
    
    # Check if the build was successful
    if [ -f "docs/generated/handbook/index.html" ]; then
        echo "🌐 Open docs/generated/handbook/index.html in your browser to view the handbook"
        
        # Optionally start a local server
        if [ "$1" = "--serve" ]; then
            echo "🚀 Starting local documentation server..."
            mkdocs serve --dev-addr=127.0.0.1:8001
        fi
    else
        echo "❌ Build completed but index.html not found"
        exit 1
    fi
else
    echo "❌ MkDocs build failed"
    exit 1
fi

echo "🎉 Architecture handbook generation complete!"