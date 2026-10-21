#!/usr/bin/env python3
"""
WRFCoin Codebase Automation Orchestrator
Coordinates execution of all codebase analysis tools
"""

import subprocess
import sys
import time
from pathlib import Path
from datetime import datetime

class CodebaseAutomationOrchestrator:
    """Orchestrates all codebase analysis and maintenance tasks."""
    
    def __init__(self):
        self.root_path = Path(__file__).parent.parent.parent
        self.scripts = {
            "manifest": "scripts/generate_file_manifest.py",
            "categorization": "scripts/categorize_files_by_domain.py", 
            "dependencies": "scripts/analyze_dependencies.py",
            "responsibility": "scripts/generate_responsibility_matrix.py",
            "diagrams": "scripts/generate_architectural_diagrams.py",
            "integration": "scripts/unified_codebase_integration_system.py"
        }
    
    def run_full_update(self):
        """Run complete codebase analysis update."""
        print("🚀 Starting full codebase analysis update...")
        start_time = time.time()
        
        results = {}
        
        for name, script_path in self.scripts.items():
            print(f"\n🔄 Running {name}...")
            try:
                result = subprocess.run([
                    sys.executable, script_path
                ], cwd=self.root_path, capture_output=True, text=True)
                
                if result.returncode == 0:
                    print(f"   ✅ {name} completed successfully")
                    results[name] = "success"
                else:
                    print(f"   ❌ {name} failed: {result.stderr}")
                    results[name] = "failed"
                    
            except Exception as e:
                print(f"   ❌ {name} error: {e}")
                results[name] = "error"
        
        # Generate summary
        total_time = time.time() - start_time
        successful = sum(1 for r in results.values() if r == "success")
        total = len(results)
        
        print(f"\n📊 AUTOMATION SUMMARY:")
        print(f"   Successful: {successful}/{total}")
        print(f"   Duration: {total_time:.2f} seconds")
        print(f"   Timestamp: {datetime.now().isoformat()}")
        
        return results
    
    def validate_outputs(self):
        """Validate all expected outputs exist."""
        expected_files = [
            "file_manifest.json",
            "file_domain_mapping.json", 
            "dependency_graph_data.json",
            "responsibility_matrix.json",
            "CODEOWNERS",
            "architectural_diagrams.html",
            "unified_dashboard.html"
        ]
        
        missing_files = []
        for file_path in expected_files:
            if not (self.root_path / file_path).exists():
                missing_files.append(file_path)
        
        if missing_files:
            print(f"⚠️ Missing files: {missing_files}")
            return False
        else:
            print("✅ All expected outputs present")
            return True

if __name__ == "__main__":
    orchestrator = CodebaseAutomationOrchestrator()
    
    if len(sys.argv) > 1 and sys.argv[1] == "--validate":
        orchestrator.validate_outputs()
    else:
        results = orchestrator.run_full_update()
        orchestrator.validate_outputs()
