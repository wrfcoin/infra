#!/usr/bin/env python3
"""
WRFCoin Codebase Domain Categorization Script
Team 2: Automated file categorization with pattern matching for Task 38

Categorizes 15,570+ files into 10 domain categories using sophisticated pattern matching.
Handles multi-domain files with primary/secondary domain assignment.
"""

import os
import re
import json
import time
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Set, Tuple, Optional
from collections import defaultdict, Counter

class DomainCategorizer:
    """Advanced domain categorization system for large codebases."""
    
    def __init__(self, manifest_path: str = "file_manifest.json", root_path: str = str(Path(__file__).resolve().parents[1])):
        self.manifest_path = Path(manifest_path)
        self.root_path = Path(root_path)
        self.domain_rules = self._initialize_domain_rules()
        self.categorization_stats = defaultdict(int)
        self.multi_domain_files = []
        self.uncategorized_files = []
        
    def _initialize_domain_rules(self) -> Dict:
        """Initialize comprehensive domain categorization rules."""
        return {
            "blockchain-core": {
                "priority": 9,  # Highest priority for most specific domain
                "path_patterns": [
                    r"^blockchain-core/",
                    r"/blockchain/",
                    r"/consensus/",
                    r"/mining/",
                    r"/validator/",
                    r"/crypto/",
                    r"/network/",
                ],
                "file_patterns": [
                    r"\.rs$",  # Rust files in blockchain context
                    r"^Cargo\.(toml|lock)$",
                    r"lib\.rs$",
                    r"main\.rs$",
                ],
                "exclude_patterns": [
                    r"/test/",
                    r"_test\.rs$",
                ],
                "content_indicators": [
                    "blockchain", "consensus", "validator", "mining", "crypto"
                ]
            },
            
            "backend-services": {
                "priority": 8,
                "path_patterns": [
                    r"^backend/",
                    r"^backend/server/",
                    r"^backend/microservices/",
                    r"^backend/services/",
                    r"^backend/api/",
                    r"^backend/routes/",
                    r"^backend/middleware/",
                    r"^backend/utils/",
                ],
                "file_patterns": [
                    r"_server\.js$",
                    r"_api\.js$",
                    r"_service\.js$",
                    r"api.*\.ts$",
                    r"server.*\.ts$",
                    r"service.*\.ts$",
                ],
                "exclude_patterns": [
                    r"/test/",
                    r"\.test\.(js|ts)$",
                ],
                "content_indicators": [
                    "express", "api", "server", "microservice", "endpoint"
                ]
            },
            
            "frontend-interface": {
                "priority": 8,
                "path_patterns": [
                    r"^frontend/",
                    r"/src/components/",
                    r"/src/pages/",
                    r"/src/hooks/",
                    r"/components/",
                    r"/pages/",
                ],
                "file_patterns": [
                    r"\.(tsx|jsx)$",
                    r"\.css$",
                    r"\.scss$",
                    r"\.less$",
                    r"\.sass$",
                    r"vite\.config\.js$",
                ],
                "exclude_patterns": [
                    r"\.test\.(tsx|jsx|ts|js)$",
                    r"/test/",
                ],
                "content_indicators": [
                    "react", "component", "hook", "jsx", "tsx"
                ]
            },
            
            "smart-contracts": {
                "priority": 9,
                "path_patterns": [
                    r"^contracts/",
                    r"^smart-contracts/",
                    r"/contracts/",
                ],
                "file_patterns": [
                    r"\.sol$",
                    r"hardhat\.config\.js$",
                    r"truffle-config\.js$",
                ],
                "exclude_patterns": [
                    r"\.test\.sol$",
                    r"/test/",
                ],
                "content_indicators": [
                    "solidity", "contract", "pragma solidity", "function"
                ]
            },
            
            "infrastructure-devops": {
                "priority": 7,
                "path_patterns": [
                    r"^infrastructure/",
                    r"/docker/",
                    r"/kubernetes/",
                    r"/terraform/",
                    r"/helm/",
                    r"/.github/workflows/",
                ],
                "file_patterns": [
                    r"^Dockerfile",
                    r"^docker-compose.*\.ya?ml$",
                    r"\.ya?ml$",  # Kubernetes/Docker compose files
                    r"\.tf$",     # Terraform
                    r"\.hcl$",    # Terraform/Nomad
                    r"^\.github/",
                ],
                "exclude_patterns": [
                    r"/test/",
                ],
                "content_indicators": [
                    "docker", "kubernetes", "terraform", "deployment", "infrastructure"
                ]
            },
            
            "automation-scripts": {
                "priority": 6,
                "path_patterns": [
                    r"^scripts/",
                    r"/scripts/",
                    r"/automation/",
                    r"/tools/",
                ],
                "file_patterns": [
                    r"\.py$",     # Python scripts
                    r"\.sh$",     # Shell scripts
                    r"\.bash$",   # Bash scripts
                    r"\.js$",     # Node.js scripts (in scripts context)
                    r"^.*collector.*\.js$",
                    r"^.*workflow.*\.js$",
                ],
                "exclude_patterns": [
                    r"\.test\.(py|js|sh)$",
                    r"/test/",
                ],
                "content_indicators": [
                    "script", "automation", "workflow", "collector"
                ]
            },
            
            "testing-quality": {
                "priority": 7,
                "path_patterns": [
                    r"^test/",
                    r"^tests/",
                    r"^consolidated-tests/",
                    r"/test/",
                    r"/tests/",
                    r"/__tests__/",
                    r"/spec/",
                ],
                "file_patterns": [
                    r"\.test\.(js|ts|py|rs|sol)$",
                    r"\.spec\.(js|ts|py|rs)$",
                    r"^test.*\.(js|ts|py)$",
                    r"jest\.config\.js$",
                    r"playwright\.config\.js$",
                    r"cypress\.config\.js$",
                    r"\.test\.tsx?$",
                ],
                "exclude_patterns": [],
                "content_indicators": [
                    "test", "spec", "jest", "mocha", "cypress", "playwright"
                ]
            },
            
            "documentation": {
                "priority": 5,
                "path_patterns": [
                    r"^docs/",
                    r"/docs/",
                    r"/documentation/",
                ],
                "file_patterns": [
                    r"\.md$",
                    r"\.rst$",
                    r"\.txt$",
                    r"^README",
                    r"^CLAUDE\.md$",
                    r"^CHANGELOG",
                    r"^LICENSE",
                    r"\.pdf$",
                ],
                "exclude_patterns": [],
                "content_indicators": [
                    "documentation", "readme", "guide", "manual"
                ]
            },
            
            "security-compliance": {
                "priority": 8,
                "path_patterns": [
                    r"^security/",
                    r"/security/",
                    r"/compliance/",
                    r"/iso_compliance/",
                    r"/audit/",
                ],
                "file_patterns": [
                    r"^.*security.*\.(js|ts|py|rs)$",
                    r"^.*compliance.*\.(js|ts|py|rs)$",
                    r"^.*audit.*\.(js|ts|py|rs)$",
                    r"hsm.*\.(js|ts)$",
                ],
                "exclude_patterns": [
                    r"\.test\.",
                ],
                "content_indicators": [
                    "security", "compliance", "audit", "hsm", "encryption"
                ]
            },
            
            "configuration-data": {
                "priority": 3,  # Lower priority, often secondary domain
                "path_patterns": [
                    r"^config/",
                    r"/config/",
                    r"^assets/",
                    r"/assets/",
                    r"/static/",
                    r"/data/",
                ],
                "file_patterns": [
                    r"\.json$",
                    r"\.ya?ml$",
                    r"\.toml$",
                    r"\.ini$",
                    r"\.conf$",
                    r"\.cfg$",
                    r"\.env",
                    r"^package\.json$",
                    r"^package-lock\.json$",
                    r"\.lock$",
                    r"\.sql$",
                    r"\.(png|jpg|jpeg|gif|svg|ico|webp)$",
                    r"\.(mp4|webm|avi|mov)$",
                ],
                "exclude_patterns": [],
                "content_indicators": [
                    "config", "configuration", "settings", "environment"
                ]
            }
        }
    
    def _match_path_patterns(self, file_path: str, patterns: List[str]) -> bool:
        """Check if file path matches any of the given patterns."""
        for pattern in patterns:
            if re.search(pattern, file_path, re.IGNORECASE):
                return True
        return False
    
    def _match_file_patterns(self, file_name: str, patterns: List[str]) -> bool:
        """Check if file name matches any of the given patterns."""
        for pattern in patterns:
            if re.search(pattern, file_name, re.IGNORECASE):
                return True
        return False
    
    def _analyze_file_content(self, file_path: Path, indicators: List[str]) -> bool:
        """Analyze file content for domain indicators (for small text files only)."""
        try:
            if file_path.stat().st_size > 10240:  # Skip files larger than 10KB
                return False
            
            if file_path.suffix.lower() not in ['.js', '.ts', '.py', '.rs', '.md', '.txt', '.sol']:
                return False
            
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read(1024).lower()  # Read first 1KB
                return any(indicator in content for indicator in indicators)
        except (UnicodeDecodeError, PermissionError, FileNotFoundError):
            return False
    
    def categorize_file(self, file_data: Dict) -> Tuple[str, List[str]]:
        """Categorize a single file and return primary domain and all matching domains."""
        file_path = file_data["path"]
        file_name = file_data["name"]
        absolute_path = Path(file_data["absolute_path"])
        
        domain_scores = {}
        matching_domains = []
        
        # Check each domain rule
        for domain, rules in self.domain_rules.items():
            score = 0
            
            # Path pattern matching (highest weight)
            if self._match_path_patterns(file_path, rules["path_patterns"]):
                score += rules["priority"] * 3
            
            # File pattern matching (medium weight)
            if self._match_file_patterns(file_name, rules["file_patterns"]):
                score += rules["priority"] * 2
            
            # Content analysis (lower weight, expensive)
            if rules["content_indicators"] and score == 0:  # Only if no pattern matches
                if self._analyze_file_content(absolute_path, rules["content_indicators"]):
                    score += rules["priority"]
            
            # Apply exclusion patterns (negative score)
            if self._match_path_patterns(file_path, rules.get("exclude_patterns", [])):
                score = max(0, score - rules["priority"] * 2)
            
            if score > 0:
                domain_scores[domain] = score
                matching_domains.append(domain)
        
        # Determine primary domain (highest score)
        if domain_scores:
            primary_domain = max(domain_scores.keys(), key=lambda d: domain_scores[d])
            
            # For multi-domain files, include secondary domains with significant scores
            secondary_domains = [
                domain for domain, score in domain_scores.items()
                if domain != primary_domain and score >= domain_scores[primary_domain] * 0.5
            ]
            
            return primary_domain, secondary_domains
        
        # Fallback categorization based on file extension
        extension = file_data.get("extension", "").lower()
        fallback_domain = self._get_fallback_domain(extension, file_path)
        
        return fallback_domain, []
    
    def _get_fallback_domain(self, extension: str, file_path: str) -> str:
        """Provide fallback categorization for uncategorized files."""
        # Common fallback patterns
        if extension in ['.sql']:
            return 'configuration-data'
        elif extension in ['.py', '.sh', '.bash'] and '/scripts/' in file_path:
            return 'automation-scripts'
        elif extension in ['.js', '.ts'] and '/backend/' in file_path:
            return 'backend-services'
        elif extension in ['.jsx', '.tsx'] and '/frontend/' in file_path:
            return 'frontend-interface'
        elif extension in ['.rs'] and '/blockchain-core/' in file_path:
            return 'blockchain-core'
        elif extension in ['.sol']:
            return 'smart-contracts'
        elif extension in ['.md', '.txt']:
            return 'documentation'
        elif extension in ['.json', '.yaml', '.yml', '.toml', '.env']:
            return 'configuration-data'
        elif extension in ['.png', '.jpg', '.jpeg', '.gif', '.svg', '.webm', '.mp4']:
            return 'configuration-data'
        else:
            return 'configuration-data'  # Default fallback
    
    def process_file_manifest(self) -> Dict:
        """Process the complete file manifest and categorize all files."""
        print(f"Loading file manifest from {self.manifest_path}")
        
        with open(self.manifest_path, 'r', encoding='utf-8') as f:
            manifest_data = json.load(f)
        
        files = manifest_data["files"]
        total_files = len(files)
        
        print(f"Categorizing {total_files:,} files...")
        start_time = time.time()
        
        categorized_files = []
        domain_file_counts = defaultdict(int)
        
        for i, file_data in enumerate(files):
            if i % 2000 == 0 and i > 0:
                print(f"  Processed {i:,} files ({i/total_files*100:.1f}%)")
            
            primary_domain, secondary_domains = self.categorize_file(file_data)
            
            # Create enriched file record
            categorized_file = {
                **file_data,
                "primary_domain": primary_domain,
                "secondary_domains": secondary_domains,
                "all_domains": [primary_domain] + secondary_domains,
                "is_multi_domain": len(secondary_domains) > 0
            }
            
            categorized_files.append(categorized_file)
            
            # Update statistics
            domain_file_counts[primary_domain] += 1
            self.categorization_stats[primary_domain] += 1
            
            if secondary_domains:
                self.multi_domain_files.append(categorized_file)
                for domain in secondary_domains:
                    self.categorization_stats[f"{domain} (secondary)"] += 1
        
        processing_time = time.time() - start_time
        
        print(f"✅ Categorized {total_files:,} files in {processing_time:.2f} seconds")
        
        # Generate domain mapping structure
        domain_mapping = {
            "metadata": {
                "generated_at": datetime.now().isoformat(),
                "generator_version": "1.0.0",
                "source_manifest": str(self.manifest_path),
                "processing_time_seconds": round(processing_time, 2),
                "total_files_categorized": total_files,
                "multi_domain_files": len(self.multi_domain_files)
            },
            "domain_statistics": {
                "primary_domain_counts": dict(domain_file_counts),
                "total_domains": len(self.domain_rules),
                "multi_domain_percentage": round(len(self.multi_domain_files) / total_files * 100, 2)
            },
            "files": categorized_files,
            "domain_rules_used": self.domain_rules,
            "categorization_summary": dict(self.categorization_stats)
        }
        
        return domain_mapping
    
    def generate_domain_summary_report(self, domain_mapping: Dict) -> str:
        """Generate a human-readable domain summary report."""
        stats = domain_mapping["domain_statistics"]
        total_files = domain_mapping["metadata"]["total_files_categorized"]
        
        report_lines = [
            "# WRFCoin Codebase Domain Categorization Report",
            f"**Generated**: {domain_mapping['metadata']['generated_at']}",
            f"**Total Files**: {total_files:,}",
            f"**Processing Time**: {domain_mapping['metadata']['processing_time_seconds']} seconds",
            f"**Multi-Domain Files**: {domain_mapping['metadata']['multi_domain_files']} ({stats['multi_domain_percentage']}%)",
            "",
            "## Domain Distribution",
            ""
        ]
        
        # Sort domains by file count
        sorted_domains = sorted(
            stats["primary_domain_counts"].items(),
            key=lambda x: x[1],
            reverse=True
        )
        
        for domain, count in sorted_domains:
            percentage = (count / total_files) * 100
            report_lines.append(f"- **{domain}**: {count:,} files ({percentage:.1f}%)")
        
        return "\n".join(report_lines)
    
    def save_domain_mapping(self, domain_mapping: Dict, output_path: str = "file_domain_mapping.json"):
        """Save domain mapping to JSON file."""
        output_file = self.root_path / output_path
        
        print(f"Saving domain mapping to {output_file}")
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(domain_mapping, f, indent=2, ensure_ascii=False)
        
        # Also save summary report
        report_path = self.root_path / "domain_categorization_report.md"
        report_content = self.generate_domain_summary_report(domain_mapping)
        with open(report_path, 'w', encoding='utf-8') as f:
            f.write(report_content)
        
        print(f"✅ Domain mapping saved: {output_file}")
        print(f"✅ Summary report saved: {report_path}")
        return output_file

def main():
    """Main execution function."""
    categorizer = DomainCategorizer()
    
    try:
        # Process the file manifest
        domain_mapping = categorizer.process_file_manifest()
        
        # Save results
        output_path = categorizer.save_domain_mapping(domain_mapping)
        
        # Print summary
        stats = domain_mapping["domain_statistics"]
        print(f"\n📊 CATEGORIZATION SUMMARY:")
        print(f"   Total Files: {domain_mapping['metadata']['total_files_categorized']:,}")
        print(f"   Domains Used: {stats['total_domains']}")
        print(f"   Multi-Domain Files: {domain_mapping['metadata']['multi_domain_files']:,} ({stats['multi_domain_percentage']}%)")
        
        print(f"\n🏷️  TOP DOMAINS:")
        sorted_domains = sorted(
            stats["primary_domain_counts"].items(),
            key=lambda x: x[1],
            reverse=True
        )
        for domain, count in sorted_domains[:5]:
            print(f"   {domain}: {count:,} files")
        
        print(f"\n📁 OUTPUT FILES:")
        print(f"   Domain Mapping: {output_path}")
        print(f"   Summary Report: domain_categorization_report.md")
        
        return True
        
    except Exception as e:
        print(f"❌ Error during categorization: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = main()
    exit(0 if success else 1)