#!/usr/bin/env python3
"""
WRFCoin Comprehensive Dependency Analysis Script
Team 3: Multi-language dependency analysis for Task 38

Analyzes dependencies across Rust, Node.js, Python, and cross-service relationships.
Generates unified dependency graph data for visualization.
"""

import os
import re
import json
import ast
import time
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Set, Tuple, Optional
from collections import defaultdict
import subprocess

class DependencyAnalyzer:
    """Comprehensive dependency analyzer for multi-language codebases."""
    
    def __init__(self, root_path: str = str(Path(__file__).resolve().parents[1])):
        self.root_path = Path(root_path)
        self.dependencies = {
            "rust": [],
            "nodejs": [],
            "python": [],
            "typescript": [],
            "frontend": [],
            "cross_service": [],
            "internal_modules": []
        }
        self.dependency_graph = {
            "nodes": [],
            "edges": [],
            "clusters": {}
        }
        
    def analyze_rust_dependencies(self) -> Dict:
        """Analyze Rust dependencies from Cargo.toml and cargo tree output."""
        print("🦀 Analyzing Rust dependencies...")
        
        rust_deps = {
            "external_crates": [],
            "internal_modules": [],
            "workspace_deps": []
        }
        
        # Parse main Cargo.toml
        cargo_toml = self.root_path / "Cargo.toml"
        if cargo_toml.exists():
            try:
                with open(cargo_toml, 'r') as f:
                    content = f.read()
                    
                # Extract dependencies section
                deps_section = re.search(r'\[dependencies\](.*?)(?:\[|$)', content, re.DOTALL)
                if deps_section:
                    for line in deps_section.group(1).split('\n'):
                        line = line.strip()
                        if '=' in line and not line.startswith('#'):
                            dep_name = line.split('=')[0].strip()
                            rust_deps["external_crates"].append({
                                "name": dep_name,
                                "type": "external",
                                "definition": line
                            })
            except Exception as e:
                print(f"Error parsing Cargo.toml: {e}")
        
        # Parse blockchain-core Cargo.toml
        blockchain_cargo = self.root_path / "blockchain-core" / "Cargo.toml"
        if blockchain_cargo.exists():
            try:
                with open(blockchain_cargo, 'r') as f:
                    content = f.read()
                    
                # Extract dependencies
                deps_section = re.search(r'\[dependencies\](.*?)(?:\[|$)', content, re.DOTALL)
                if deps_section:
                    for line in deps_section.group(1).split('\n'):
                        line = line.strip()
                        if '=' in line and not line.startswith('#'):
                            dep_name = line.split('=')[0].strip()
                            rust_deps["external_crates"].append({
                                "name": dep_name,
                                "type": "blockchain_core",
                                "definition": line
                            })
            except Exception as e:
                print(f"Error parsing blockchain-core Cargo.toml: {e}")
        
        # Analyze internal module structure
        rust_files = list(self.root_path.glob("**/*.rs"))
        for rust_file in rust_files[:100]:  # Limit for performance
            try:
                with open(rust_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                    
                # Find mod declarations and use statements
                mod_matches = re.findall(r'mod\s+(\w+)', content)
                use_matches = re.findall(r'use\s+([^;]+);', content)
                
                for mod_name in mod_matches:
                    rust_deps["internal_modules"].append({
                        "file": str(rust_file.relative_to(self.root_path)),
                        "module": mod_name,
                        "type": "module_declaration"
                    })
                
                for use_stmt in use_matches:
                    rust_deps["internal_modules"].append({
                        "file": str(rust_file.relative_to(self.root_path)),
                        "import": use_stmt.strip(),
                        "type": "use_statement"
                    })
                    
            except Exception as e:
                continue  # Skip files that can't be read
        
        self.dependencies["rust"] = rust_deps
        print(f"   Found {len(rust_deps['external_crates'])} external crates")
        print(f"   Found {len(rust_deps['internal_modules'])} internal dependencies")
        
        return rust_deps
    
    def analyze_nodejs_dependencies(self) -> Dict:
        """Analyze Node.js dependencies from package.json and import statements."""
        print("📦 Analyzing Node.js dependencies...")
        
        nodejs_deps = {
            "production_deps": [],
            "dev_deps": [],
            "internal_imports": [],
            "service_endpoints": []
        }
        
        # Parse main package.json
        package_json = self.root_path / "package.json"
        if package_json.exists():
            try:
                with open(package_json, 'r') as f:
                    package_data = json.load(f)
                    
                # Production dependencies
                for name, version in package_data.get("dependencies", {}).items():
                    nodejs_deps["production_deps"].append({
                        "name": name,
                        "version": version,
                        "type": "production"
                    })
                
                # Development dependencies
                for name, version in package_data.get("devDependencies", {}).items():
                    nodejs_deps["dev_deps"].append({
                        "name": name,
                        "version": version,
                        "type": "development"
                    })
                    
            except Exception as e:
                print(f"Error parsing package.json: {e}")
        
        # Parse existing nodejs dependencies JSON
        nodejs_json = self.root_path / "nodejs_dependencies.json"
        if nodejs_json.exists():
            try:
                with open(nodejs_json, 'r') as f:
                    npm_data = json.load(f)
                    
                # Process npm ls output
                if "dependencies" in npm_data:
                    self._process_npm_dependencies(npm_data["dependencies"], nodejs_deps)
                    
            except Exception as e:
                print(f"Error parsing nodejs_dependencies.json: {e}")
        
        # Analyze JavaScript/TypeScript imports
        js_files = list(self.root_path.glob("**/*.js")) + list(self.root_path.glob("**/*.ts"))
        for js_file in js_files[:200]:  # Limit for performance
            if "node_modules" in str(js_file) or "test" in str(js_file):
                continue
                
            try:
                with open(js_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                    
                # Find import/require statements
                import_matches = re.findall(r'(?:import.*?from\s+[\'"]([^\'"]+)[\'"]|require\([\'"]([^\'"]+)[\'"]\))', content)
                
                for match in import_matches:
                    import_path = match[0] or match[1]
                    if import_path:
                        nodejs_deps["internal_imports"].append({
                            "file": str(js_file.relative_to(self.root_path)),
                            "import": import_path,
                            "type": "import" if match[0] else "require"
                        })
                        
            except Exception as e:
                continue
        
        self.dependencies["nodejs"] = nodejs_deps
        print(f"   Found {len(nodejs_deps['production_deps'])} production dependencies")
        print(f"   Found {len(nodejs_deps['dev_deps'])} dev dependencies")
        print(f"   Found {len(nodejs_deps['internal_imports'])} internal imports")
        
        return nodejs_deps
    
    def _process_npm_dependencies(self, deps: Dict, nodejs_deps: Dict, depth: int = 0):
        """Recursively process npm dependency tree."""
        if depth > 3:  # Limit recursion depth
            return
            
        for name, info in deps.items():
            if isinstance(info, dict):
                nodejs_deps["production_deps"].append({
                    "name": name,
                    "version": info.get("version", "unknown"),
                    "type": "npm_tree",
                    "depth": depth
                })
                
                if "dependencies" in info:
                    self._process_npm_dependencies(info["dependencies"], nodejs_deps, depth + 1)
    
    def analyze_python_dependencies(self) -> Dict:
        """Analyze Python dependencies and imports."""
        print("🐍 Analyzing Python dependencies...")
        
        python_deps = {
            "imports": [],
            "modules": [],
            "scripts": []
        }
        
        # Find Python files
        python_files = list(self.root_path.glob("**/*.py"))
        for py_file in python_files[:100]:  # Limit for performance
            try:
                with open(py_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                    
                # Parse imports using AST
                try:
                    tree = ast.parse(content)
                    for node in ast.walk(tree):
                        if isinstance(node, ast.Import):
                            for alias in node.names:
                                python_deps["imports"].append({
                                    "file": str(py_file.relative_to(self.root_path)),
                                    "module": alias.name,
                                    "type": "import"
                                })
                        elif isinstance(node, ast.ImportFrom):
                            if node.module:
                                python_deps["imports"].append({
                                    "file": str(py_file.relative_to(self.root_path)),
                                    "module": node.module,
                                    "type": "from_import"
                                })
                except SyntaxError:
                    # Fall back to regex for malformed Python
                    import_matches = re.findall(r'(?:^import\s+(\S+)|^from\s+(\S+)\s+import)', content, re.MULTILINE)
                    for match in import_matches:
                        module = match[0] or match[1]
                        if module:
                            python_deps["imports"].append({
                                "file": str(py_file.relative_to(self.root_path)),
                                "module": module,
                                "type": "regex_import"
                            })
                            
            except Exception as e:
                continue
        
        self.dependencies["python"] = python_deps
        print(f"   Found {len(python_deps['imports'])} Python imports")
        
        return python_deps
    
    def analyze_cross_service_dependencies(self) -> Dict:
        """Analyze cross-service and API dependencies."""
        print("🔗 Analyzing cross-service dependencies...")
        
        cross_deps = {
            "api_endpoints": [],
            "service_communications": [],
            "database_connections": [],
            "websocket_connections": []
        }
        
        # Analyze API endpoints and service communications
        service_files = list(self.root_path.glob("backend/server/*.js")) + list(self.root_path.glob("backend/server/*.ts"))
        
        for service_file in service_files:
            try:
                with open(service_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                    
                # Find port definitions
                port_matches = re.findall(r'(?:port|PORT).*?(\d{4,5})', content)
                for port in port_matches:
                    cross_deps["api_endpoints"].append({
                        "service": service_file.name,
                        "port": int(port),
                        "file": str(service_file.relative_to(self.root_path))
                    })
                
                # Find database connections
                db_matches = re.findall(r'(?:DATABASE_URL|mongodb|postgres|redis)', content, re.IGNORECASE)
                if db_matches:
                    cross_deps["database_connections"].append({
                        "service": service_file.name,
                        "file": str(service_file.relative_to(self.root_path)),
                        "db_types": list(set(db_matches))
                    })
                
                # Find WebSocket connections
                ws_matches = re.findall(r'(?:websocket|ws|socket\.io)', content, re.IGNORECASE)
                if ws_matches:
                    cross_deps["websocket_connections"].append({
                        "service": service_file.name,
                        "file": str(service_file.relative_to(self.root_path))
                    })
                    
            except Exception as e:
                continue
        
        self.dependencies["cross_service"] = cross_deps
        print(f"   Found {len(cross_deps['api_endpoints'])} API endpoints")
        print(f"   Found {len(cross_deps['database_connections'])} database connections")
        
        return cross_deps
    
    def generate_dependency_graph_data(self) -> Dict:
        """Generate unified dependency graph data structure."""
        print("📊 Generating dependency graph data...")
        
        nodes = []
        edges = []
        node_id_map = {}
        current_id = 0
        
        # Add domain clusters as high-level nodes
        domains = [
            "blockchain-core", "backend-services", "frontend-interface", 
            "smart-contracts", "automation-scripts", "infrastructure-devops"
        ]
        
        for domain in domains:
            node_id_map[domain] = current_id
            nodes.append({
                "id": current_id,
                "label": domain,
                "type": "domain",
                "group": "domain",
                "size": 30
            })
            current_id += 1
        
        # Add Rust crate nodes
        for crate in self.dependencies["rust"]["external_crates"][:20]:  # Limit nodes
            node_id = current_id
            node_id_map[f"rust:{crate['name']}"] = node_id
            nodes.append({
                "id": node_id,
                "label": crate["name"],
                "type": "rust_crate",
                "group": "rust",
                "size": 10
            })
            current_id += 1
            
            # Add edge to blockchain-core domain
            edges.append({
                "from": node_id_map["blockchain-core"],
                "to": node_id,
                "type": "dependency",
                "weight": 1
            })
        
        # Add Node.js package nodes
        for pkg in self.dependencies["nodejs"]["production_deps"][:20]:  # Limit nodes
            node_id = current_id
            node_id_map[f"npm:{pkg['name']}"] = node_id
            nodes.append({
                "id": node_id,
                "label": pkg["name"],
                "type": "npm_package",
                "group": "nodejs",
                "size": 8
            })
            current_id += 1
            
            # Add edge to backend-services domain
            edges.append({
                "from": node_id_map["backend-services"],
                "to": node_id,
                "type": "dependency",
                "weight": 1
            })
        
        # Add service communication edges
        for service in self.dependencies["cross_service"]["api_endpoints"]:
            service_key = f"service:{service['service']}"
            if service_key not in node_id_map:
                node_id_map[service_key] = current_id
                nodes.append({
                    "id": current_id,
                    "label": f"{service['service']}:{service['port']}",
                    "type": "service",
                    "group": "service",
                    "size": 15
                })
                current_id += 1
                
                # Connect to backend-services domain
                edges.append({
                    "from": node_id_map["backend-services"],
                    "to": node_id_map[service_key],
                    "type": "contains",
                    "weight": 2
                })
        
        self.dependency_graph = {
            "nodes": nodes,
            "edges": edges,
            "metadata": {
                "total_nodes": len(nodes),
                "total_edges": len(edges),
                "generated_at": datetime.now().isoformat()
            }
        }
        
        return self.dependency_graph
    
    def run_comprehensive_analysis(self) -> Dict:
        """Run comprehensive dependency analysis across all languages."""
        print("🔍 Starting comprehensive dependency analysis...")
        start_time = time.time()
        
        # Run all analyses
        rust_deps = self.analyze_rust_dependencies()
        nodejs_deps = self.analyze_nodejs_dependencies()
        python_deps = self.analyze_python_dependencies()
        cross_deps = self.analyze_cross_service_dependencies()
        
        # Generate unified graph
        graph_data = self.generate_dependency_graph_data()
        
        processing_time = time.time() - start_time
        
        # Create comprehensive report
        analysis_report = {
            "metadata": {
                "generated_at": datetime.now().isoformat(),
                "processing_time_seconds": round(processing_time, 2),
                "analyzer_version": "1.0.0"
            },
            "summary": {
                "rust_external_crates": len(rust_deps["external_crates"]),
                "rust_internal_modules": len(rust_deps["internal_modules"]),
                "nodejs_production_deps": len(nodejs_deps["production_deps"]),
                "nodejs_dev_deps": len(nodejs_deps["dev_deps"]),
                "nodejs_internal_imports": len(nodejs_deps["internal_imports"]),
                "python_imports": len(python_deps["imports"]),
                "api_endpoints": len(cross_deps["api_endpoints"]),
                "database_connections": len(cross_deps["database_connections"]),
                "total_graph_nodes": len(graph_data["nodes"]),
                "total_graph_edges": len(graph_data["edges"])
            },
            "dependencies": self.dependencies,
            "dependency_graph": graph_data
        }
        
        print(f"✅ Analysis completed in {processing_time:.2f} seconds")
        return analysis_report
    
    def save_dependency_data(self, analysis_report: Dict, output_path: str = "dependency_graph_data.json"):
        """Save dependency analysis data to JSON file."""
        output_file = self.root_path / output_path
        
        print(f"Saving dependency data to {output_file}")
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(analysis_report, f, indent=2, ensure_ascii=False)
        
        print(f"✅ Dependency data saved: {output_file}")
        return output_file

def main():
    """Main execution function."""
    analyzer = DependencyAnalyzer()
    
    try:
        # Run comprehensive analysis
        analysis_report = analyzer.run_comprehensive_analysis()
        
        # Save results
        output_path = analyzer.save_dependency_data(analysis_report)
        
        # Print summary
        summary = analysis_report["summary"]
        print(f"\n📊 DEPENDENCY ANALYSIS SUMMARY:")
        print(f"   Rust External Crates: {summary['rust_external_crates']}")
        print(f"   Node.js Production Deps: {summary['nodejs_production_deps']}")
        print(f"   Node.js Dev Deps: {summary['nodejs_dev_deps']}")
        print(f"   Python Imports: {summary['python_imports']}")
        print(f"   API Endpoints: {summary['api_endpoints']}")
        print(f"   Graph Nodes: {summary['total_graph_nodes']}")
        print(f"   Graph Edges: {summary['total_graph_edges']}")
        print(f"   Output: {output_path}")
        
        return True
        
    except Exception as e:
        print(f"❌ Error during dependency analysis: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = main()
    exit(0 if success else 1)