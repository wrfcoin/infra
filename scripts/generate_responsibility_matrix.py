#!/usr/bin/env python3
"""
WRFCoin Responsibility Matrix Generator
Team 5: Code ownership and maintainer assignment for Task 38

Analyzes git history, existing documentation, and domain patterns to assign
maintainers and subject matter experts to each file and domain.
"""

import os
import re
import json
import subprocess
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Set, Optional
from collections import defaultdict, Counter

class ResponsibilityMatrixGenerator:
    """Generate responsibility matrix with maintainer assignments."""
    
    def __init__(self, root_path: str = str(Path(__file__).resolve().parents[1])):
        self.root_path = Path(root_path)
        self.domain_experts = self._initialize_domain_experts()
        self.git_authors = {}
        self.claude_maintainers = {}
        self.responsibility_matrix = {}
        
    def _initialize_domain_experts(self) -> Dict:
        """Initialize domain expert assignments based on WRFCoin architecture."""
        return {
            "blockchain-core": {
                "primary_sme": "Core Blockchain Team",
                "expertise": ["Rust", "Consensus", "Cryptography", "P2P Networking"],
                "responsibilities": [
                    "Consensus mechanism maintenance",
                    "Cryptographic security",
                    "Network protocol implementation",
                    "Mining and validation logic",
                    "Cross-chain bridge protocols"
                ]
            },
            "backend-services": {
                "primary_sme": "Backend Services Team", 
                "expertise": ["Node.js", "TypeScript", "Express", "Microservices"],
                "responsibilities": [
                    "API endpoint development",
                    "Microservice orchestration", 
                    "Database integration",
                    "Service middleware",
                    "Authentication and authorization"
                ]
            },
            "frontend-interface": {
                "primary_sme": "Frontend Team",
                "expertise": ["React", "TypeScript", "Material-UI", "Vite"],
                "responsibilities": [
                    "User interface development",
                    "Component library maintenance",
                    "State management",
                    "Performance optimization",
                    "Accessibility compliance"
                ]
            },
            "smart-contracts": {
                "primary_sme": "Smart Contract Team",
                "expertise": ["Solidity", "Hardhat", "OpenZeppelin", "DeFi"],
                "responsibilities": [
                    "Contract development and deployment",
                    "Security auditing",
                    "Gas optimization",
                    "Protocol governance",
                    "Token economics"
                ]
            },
            "infrastructure-devops": {
                "primary_sme": "DevOps Team",
                "expertise": ["Docker", "Kubernetes", "Terraform", "CI/CD"],
                "responsibilities": [
                    "Container orchestration",
                    "Infrastructure as code",
                    "Deployment automation",
                    "Monitoring and alerting",
                    "Security hardening"
                ]
            },
            "automation-scripts": {
                "primary_sme": "Automation Team",
                "expertise": ["Python", "Bash", "Node.js", "Workflow"],
                "responsibilities": [
                    "Collection script maintenance",
                    "Workflow automation",
                    "Data processing pipelines",
                    "Performance monitoring",
                    "System integration"
                ]
            },
            "testing-quality": {
                "primary_sme": "QA Team",
                "expertise": ["Jest", "Playwright", "Cypress", "Quality Assurance"],
                "responsibilities": [
                    "Test framework maintenance",
                    "Quality gate enforcement",
                    "Performance testing",
                    "Integration testing",
                    "Security testing"
                ]
            },
            "documentation": {
                "primary_sme": "Documentation Team",
                "expertise": ["Technical Writing", "Markdown", "Architecture"],
                "responsibilities": [
                    "Documentation maintenance",
                    "Architecture documentation",
                    "API documentation",
                    "User guides",
                    "Knowledge management"
                ]
            },
            "security-compliance": {
                "primary_sme": "Security Team",
                "expertise": ["Security", "Compliance", "HSM", "Auditing"],
                "responsibilities": [
                    "Security implementation",
                    "Compliance frameworks",
                    "Vulnerability management",
                    "HSM integration",
                    "Security auditing"
                ]
            },
            "configuration-data": {
                "primary_sme": "Platform Team",
                "expertise": ["Configuration", "Data Management", "Assets"],
                "responsibilities": [
                    "Configuration management",
                    "Data asset maintenance",
                    "Environment management",
                    "Schema management",
                    "Static resource management"
                ]
            }
        }
    
    def analyze_git_history(self) -> Dict:
        """Analyze git commit history to identify frequent contributors by domain."""
        print("📈 Analyzing git history for contributor patterns...")
        
        git_authors = defaultdict(lambda: defaultdict(int))
        
        try:
            # Get commit history with file changes
            cmd = ['git', 'log', '--name-only', '--pretty=format:%ae|%an|%ad', '--date=short']
            result = subprocess.run(cmd, cwd=self.root_path, capture_output=True, text=True)
            
            if result.returncode != 0:
                print(f"Git log failed: {result.stderr}")
                return {}
            
            lines = result.stdout.split('\n')
            current_author = None
            
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                    
                if '|' in line:  # Author line
                    parts = line.split('|')
                    if len(parts) >= 2:
                        current_author = parts[1].strip()
                else:  # File line
                    if current_author and line:
                        # Categorize file by path
                        domain = self._categorize_file_path(line)
                        git_authors[domain][current_author] += 1
            
            self.git_authors = dict(git_authors)
            
            print(f"   Analyzed git history for {len(git_authors)} domains")
            return self.git_authors
            
        except Exception as e:
            print(f"Error analyzing git history: {e}")
            return {}
    
    def _categorize_file_path(self, file_path: str) -> str:
        """Categorize file path into domain."""
        if file_path.startswith('blockchain-core/'):
            return 'blockchain-core'
        elif file_path.startswith('backend/'):
            return 'backend-services'
        elif file_path.startswith('frontend/'):
            return 'frontend-interface'
        elif file_path.startswith('contracts/') or file_path.startswith('smart-contracts/'):
            return 'smart-contracts'
        elif file_path.startswith('infrastructure/') or 'docker' in file_path.lower():
            return 'infrastructure-devops'
        elif file_path.startswith('scripts/'):
            return 'automation-scripts'
        elif file_path.startswith('test/') or file_path.startswith('tests/'):
            return 'testing-quality'
        elif file_path.startswith('docs/') or file_path.endswith('.md'):
            return 'documentation'
        elif file_path.startswith('security/'):
            return 'security-compliance'
        else:
            return 'configuration-data'
    
    def analyze_claude_documentation(self) -> Dict:
        """Analyze existing CLAUDE.md files for maintainer information."""
        print("📚 Analyzing CLAUDE.md files for maintainer patterns...")
        
        claude_files = list(self.root_path.glob("**/CLAUDE.md"))
        maintainers = {}
        
        for claude_file in claude_files:
            try:
                with open(claude_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                    
                # Extract domain from file location
                relative_path = claude_file.relative_to(self.root_path)
                domain = self._categorize_file_path(str(relative_path))
                
                # Look for maintainer patterns in content
                maintainer_patterns = [
                    r'maintainer[s]?[:\s]+([^\n]+)',
                    r'owner[s]?[:\s]+([^\n]+)',
                    r'responsible[:\s]+([^\n]+)',
                    r'contact[:\s]+([^\n]+)'
                ]
                
                found_maintainers = []
                for pattern in maintainer_patterns:
                    matches = re.findall(pattern, content, re.IGNORECASE)
                    found_maintainers.extend(matches)
                
                if found_maintainers:
                    maintainers[domain] = found_maintainers
                    
                # Extract technology stack information
                tech_patterns = [
                    r'technolog(?:y|ies)[:\s]+([^\n]+)',
                    r'stack[:\s]+([^\n]+)',
                    r'framework[s]?[:\s]+([^\n]+)'
                ]
                
                for pattern in tech_patterns:
                    matches = re.findall(pattern, content, re.IGNORECASE)
                    if matches and domain in self.domain_experts:
                        # Update domain expertise
                        for match in matches:
                            techs = [t.strip() for t in match.split(',')]
                            self.domain_experts[domain]["expertise"].extend(techs)
                        
            except Exception as e:
                print(f"Error reading {claude_file}: {e}")
                continue
        
        self.claude_maintainers = maintainers
        print(f"   Found maintainer info in {len(maintainers)} domains")
        return maintainers
    
    def generate_responsibility_matrix(self) -> Dict:
        """Generate comprehensive responsibility matrix."""
        print("🏗️ Generating responsibility matrix...")
        
        # Load domain mapping
        try:
            with open(self.root_path / 'file_domain_mapping.json', 'r') as f:
                domain_mapping = json.load(f)
        except FileNotFoundError:
            print("Warning: file_domain_mapping.json not found")
            domain_mapping = {"files": []}
        
        matrix = {
            "metadata": {
                "generated_at": datetime.now().isoformat(),
                "generator_version": "1.0.0",
                "total_files": len(domain_mapping.get("files", [])),
                "total_domains": len(self.domain_experts)
            },
            "domain_assignments": {},
            "file_assignments": {},
            "team_structure": self.domain_experts,
            "contributor_analysis": self.git_authors,
            "documentation_maintainers": self.claude_maintainers
        }
        
        # Generate domain-level assignments
        for domain, expertise in self.domain_experts.items():
            # Get top contributors from git history
            top_contributors = []
            if domain in self.git_authors:
                sorted_contributors = sorted(
                    self.git_authors[domain].items(),
                    key=lambda x: x[1],
                    reverse=True
                )
                top_contributors = [name for name, _ in sorted_contributors[:3]]
            
            # Combine with CLAUDE.md maintainers
            claude_maintainers = self.claude_maintainers.get(domain, [])
            
            matrix["domain_assignments"][domain] = {
                "primary_sme": expertise["primary_sme"],
                "expertise_areas": expertise["expertise"],
                "responsibilities": expertise["responsibilities"],
                "top_contributors": top_contributors,
                "documented_maintainers": claude_maintainers,
                "assignment_confidence": "high" if (top_contributors or claude_maintainers) else "medium"
            }
        
        # Generate file-level assignments
        file_assignments = {}
        for file_data in domain_mapping.get("files", []):
            file_path = file_data["path"]
            primary_domain = file_data.get("primary_domain", "configuration-data")
            
            # Assign based on primary domain
            domain_assignment = matrix["domain_assignments"].get(primary_domain, {})
            
            file_assignments[file_path] = {
                "primary_domain": primary_domain,
                "assigned_team": domain_assignment.get("primary_sme", "Platform Team"),
                "expertise_required": domain_assignment.get("expertise_areas", []),
                "file_type": file_data.get("file_category", "other"),
                "size": file_data.get("size", 0),
                "last_modified": file_data.get("modified_time", "unknown")
            }
        
        matrix["file_assignments"] = file_assignments
        
        # Generate summary statistics
        team_file_counts = defaultdict(int)
        for assignment in file_assignments.values():
            team_file_counts[assignment["assigned_team"]] += 1
        
        matrix["summary_statistics"] = {
            "files_per_team": dict(team_file_counts),
            "total_assigned_files": len(file_assignments),
            "unassigned_files": 0,  # All files are assigned to at least one domain
            "coverage_percentage": 100.0
        }
        
        self.responsibility_matrix = matrix
        print(f"   Generated assignments for {len(file_assignments)} files")
        print(f"   Assigned to {len(team_file_counts)} teams")
        
        return matrix
    
    def generate_codeowners_file(self) -> str:
        """Generate GitHub CODEOWNERS file content."""
        print("📝 Generating CODEOWNERS file...")
        
        codeowners_content = [
            "# WRFCoin Codebase Ownership",
            "# This file defines code ownership for automatic review assignment",
            "# Generated by Task 38 - Inventory and Map Codebase",
            f"# Generated on: {datetime.now().isoformat()}",
            "",
            "# Default owners for entire repository",
            "* @wrfcoin/core-team",
            "",
            "# Domain-specific ownership",
        ]
        
        # Domain-based patterns
        domain_patterns = {
            "blockchain-core": ["blockchain-core/", "*.rs", "Cargo.toml", "Cargo.lock"],
            "backend-services": ["backend/", "backend/server/", "backend/api/"],
            "frontend-interface": ["frontend/", "*.tsx", "*.jsx", "vite.config.js"],
            "smart-contracts": ["contracts/", "smart-contracts/", "*.sol", "hardhat.config.js"],
            "infrastructure-devops": ["infrastructure/", "docker-compose*.yml", "Dockerfile*", "*.tf"],
            "automation-scripts": ["scripts/", "*.py", "*.sh"],
            "testing-quality": ["test/", "tests/", "*.test.*", "jest.config.js", "playwright.config.js"],
            "documentation": ["docs/", "*.md", "README*"],
            "security-compliance": ["security/", "*security*", "*compliance*"],
            "configuration-data": ["config/", "*.json", "*.yaml", "*.yml", "*.env*"]
        }
        
        team_handles = {
            "Core Blockchain Team": "@wrfcoin/blockchain-team",
            "Backend Services Team": "@wrfcoin/backend-team", 
            "Frontend Team": "@wrfcoin/frontend-team",
            "Smart Contract Team": "@wrfcoin/contracts-team",
            "DevOps Team": "@wrfcoin/devops-team",
            "Automation Team": "@wrfcoin/automation-team",
            "QA Team": "@wrfcoin/qa-team",
            "Documentation Team": "@wrfcoin/docs-team",
            "Security Team": "@wrfcoin/security-team",
            "Platform Team": "@wrfcoin/platform-team"
        }
        
        for domain, assignment in self.responsibility_matrix.get("domain_assignments", {}).items():
            team_name = assignment["primary_sme"]
            team_handle = team_handles.get(team_name, "@wrfcoin/core-team")
            
            codeowners_content.append(f"\n# {domain} - {team_name}")
            
            patterns = domain_patterns.get(domain, [])
            for pattern in patterns:
                codeowners_content.append(f"{pattern} {team_handle}")
        
        return "\n".join(codeowners_content)
    
    def run_comprehensive_analysis(self) -> Dict:
        """Run complete responsibility matrix generation."""
        print("🔍 Starting comprehensive responsibility analysis...")
        
        # Run all analyses
        self.analyze_git_history()
        self.analyze_claude_documentation()
        matrix = self.generate_responsibility_matrix()
        
        return matrix
    
    def save_responsibility_data(self, matrix: Dict, 
                               output_path: str = "responsibility_matrix.json",
                               codeowners_path: str = "CODEOWNERS"):
        """Save responsibility matrix and CODEOWNERS file."""
        
        # Save JSON matrix
        output_file = self.root_path / output_path
        print(f"Saving responsibility matrix to {output_file}")
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(matrix, f, indent=2, ensure_ascii=False)
        
        # Save CODEOWNERS file
        codeowners_content = self.generate_codeowners_file()
        codeowners_file = self.root_path / codeowners_path
        print(f"Saving CODEOWNERS file to {codeowners_file}")
        with open(codeowners_file, 'w', encoding='utf-8') as f:
            f.write(codeowners_content)
        
        print(f"✅ Responsibility data saved:")
        print(f"   Matrix: {output_file}")
        print(f"   CODEOWNERS: {codeowners_file}")
        
        return output_file, codeowners_file

def main():
    """Main execution function."""
    generator = ResponsibilityMatrixGenerator()
    
    try:
        # Run comprehensive analysis
        matrix = generator.run_comprehensive_analysis()
        
        # Save results
        matrix_file, codeowners_file = generator.save_responsibility_data(matrix)
        
        # Print summary
        stats = matrix["summary_statistics"]
        assignments = matrix["domain_assignments"]
        
        print(f"\n📊 RESPONSIBILITY MATRIX SUMMARY:")
        print(f"   Total Files Assigned: {stats['total_assigned_files']:,}")
        print(f"   Coverage: {stats['coverage_percentage']:.1f}%")
        print(f"   Teams: {len(stats['files_per_team'])}")
        print(f"   Domains: {len(assignments)}")
        
        print(f"\n👥 TEAM ASSIGNMENTS:")
        for team, count in sorted(stats["files_per_team"].items(), key=lambda x: x[1], reverse=True):
            print(f"   {team}: {count:,} files")
        
        print(f"\n📁 OUTPUT FILES:")
        print(f"   Responsibility Matrix: {matrix_file}")
        print(f"   CODEOWNERS: {codeowners_file}")
        
        return True
        
    except Exception as e:
        print(f"❌ Error generating responsibility matrix: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = main()
    exit(0 if success else 1)