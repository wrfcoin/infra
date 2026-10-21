#!/usr/bin/env python3
"""
WRFCoin Codebase File Manifest Generator
Team 1: Comprehensive file inventory with metadata for Task 38

Generates complete file manifest excluding dependencies and build artifacts.
Optimized for 21K+ file handling with parallel processing.
"""

import os
import json
import time
import hashlib
import mimetypes
from pathlib import Path
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Dict, List, Optional, Tuple
import threading

class FileManifestGenerator:
    """High-performance file manifest generator for large codebases."""
    
    def __init__(self, root_path: str = str(Path(__file__).resolve().parents[1])):
        self.root_path = Path(root_path)
        self.excluded_dirs = {
            'node_modules', 'target', '.git', '__pycache__', '.next',
            'dist', 'build', 'coverage', '.nyc_output', 'tmp', 'cache',
            'artifacts', 'out', '.turbo', '.vercel', '.cache'
        }
        self.excluded_files = {
            '.DS_Store', 'Thumbs.db', '*.log', '*.tmp', '*.temp'
        }
        self.manifest_data = {}
        self.lock = threading.Lock()
        self.processed_count = 0
        self.total_files = 0
        
    def should_exclude_path(self, path: Path) -> bool:
        """Check if path should be excluded from manifest."""
        # Check if any parent directory is excluded
        for part in path.parts:
            if part in self.excluded_dirs:
                return True
        
        # Check file patterns
        if path.name.startswith('.') and path.name not in {'.gitignore', '.env.example', '.claude', '.taskmaster'}:
            return True
            
        return False
    
    def get_file_metadata(self, file_path: Path) -> Optional[Dict]:
        """Extract comprehensive metadata for a single file."""
        try:
            stat = file_path.stat()
            
            # Determine file type
            mime_type, _ = mimetypes.guess_type(str(file_path))
            extension = file_path.suffix.lower()
            
            # Categorize file type
            file_category = self.categorize_file_type(extension, mime_type)
            
            # Calculate relative path from project root
            relative_path = str(file_path.relative_to(self.root_path))
            
            metadata = {
                "path": relative_path,
                "absolute_path": str(file_path),
                "name": file_path.name,
                "extension": extension,
                "size": stat.st_size,
                "size_human": self.format_bytes(stat.st_size),
                "modified_time": datetime.fromtimestamp(stat.st_mtime).isoformat(),
                "created_time": datetime.fromtimestamp(stat.st_ctime).isoformat(),
                "mime_type": mime_type,
                "file_category": file_category,
                "depth": len(file_path.relative_to(self.root_path).parts),
                "parent_directory": str(file_path.parent.relative_to(self.root_path))
            }
            
            # Add content hash for small text files (< 1MB)
            if stat.st_size < 1024 * 1024 and file_category in ['source', 'config', 'documentation']:
                try:
                    with open(file_path, 'rb') as f:
                        content = f.read()
                        metadata["sha256"] = hashlib.sha256(content).hexdigest()
                        
                        # Line count for text files
                        if file_category in ['source', 'documentation']:
                            try:
                                text_content = content.decode('utf-8')
                                metadata["line_count"] = len(text_content.splitlines())
                            except UnicodeDecodeError:
                                pass
                except (IOError, OSError):
                    pass
            
            return metadata
            
        except (OSError, IOError) as e:
            print(f"Error processing {file_path}: {e}")
            return None
    
    def categorize_file_type(self, extension: str, mime_type: Optional[str]) -> str:
        """Categorize file into broad types."""
        source_extensions = {
            '.rs', '.js', '.ts', '.tsx', '.jsx', '.py', '.sol', '.go', 
            '.java', '.c', '.cpp', '.h', '.hpp', '.rb', '.php', '.sh', '.bash'
        }
        
        config_extensions = {
            '.json', '.yaml', '.yml', '.toml', '.ini', '.conf', '.cfg',
            '.env', '.properties', '.xml'
        }
        
        doc_extensions = {
            '.md', '.txt', '.rst', '.adoc', '.tex', '.pdf', '.doc', '.docx'
        }
        
        if extension in source_extensions:
            return 'source'
        elif extension in config_extensions:
            return 'config'
        elif extension in doc_extensions:
            return 'documentation'
        elif extension in {'.css', '.scss', '.less', '.sass'}:
            return 'style'
        elif extension in {'.html', '.htm', '.xhtml'}:
            return 'markup'
        elif extension in {'.png', '.jpg', '.jpeg', '.gif', '.svg', '.ico', '.webp'}:
            return 'image'
        elif extension in {'.mp4', '.webm', '.avi', '.mov'}:
            return 'video'
        elif extension in {'.sql'}:
            return 'database'
        elif extension in {'.lock'}:
            return 'dependency_lock'
        else:
            return 'other'
    
    def format_bytes(self, bytes_size: int) -> str:
        """Format bytes into human readable format."""
        for unit in ['B', 'KB', 'MB', 'GB']:
            if bytes_size < 1024.0:
                return f"{bytes_size:.1f} {unit}"
            bytes_size /= 1024.0
        return f"{bytes_size:.1f} TB"
    
    def process_file_batch(self, file_paths: List[Path]) -> List[Dict]:
        """Process a batch of files in parallel."""
        batch_results = []
        
        for file_path in file_paths:
            if file_path.is_file() and not self.should_exclude_path(file_path):
                metadata = self.get_file_metadata(file_path)
                if metadata:
                    batch_results.append(metadata)
                    
                    with self.lock:
                        self.processed_count += 1
                        if self.processed_count % 1000 == 0:
                            print(f"Processed {self.processed_count} files...")
        
        return batch_results
    
    def collect_all_files(self) -> List[Path]:
        """Collect all file paths to process."""
        print("Collecting file paths...")
        all_files = []
        
        for file_path in self.root_path.rglob("*"):
            if file_path.is_file() and not self.should_exclude_path(file_path):
                all_files.append(file_path)
        
        self.total_files = len(all_files)
        print(f"Found {self.total_files} files to process")
        return all_files
    
    def generate_manifest(self, max_workers: int = 8, batch_size: int = 100) -> Dict:
        """Generate comprehensive file manifest with parallel processing."""
        print(f"Starting file manifest generation for {self.root_path}")
        start_time = time.time()
        
        # Collect all files
        all_files = self.collect_all_files()
        
        # Process files in batches with thread pool
        all_metadata = []
        file_batches = [all_files[i:i + batch_size] for i in range(0, len(all_files), batch_size)]
        
        print(f"Processing {len(file_batches)} batches with {max_workers} workers...")
        
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            future_to_batch = {
                executor.submit(self.process_file_batch, batch): batch 
                for batch in file_batches
            }
            
            for future in as_completed(future_to_batch):
                batch_results = future.result()
                all_metadata.extend(batch_results)
        
        # Organize data by categories
        categorized_files = {}
        extension_stats = {}
        size_stats = {"total_size": 0, "file_count": len(all_metadata)}
        
        for file_data in all_metadata:
            # Categorize by file type
            category = file_data["file_category"]
            if category not in categorized_files:
                categorized_files[category] = []
            categorized_files[category].append(file_data)
            
            # Extension statistics
            ext = file_data["extension"]
            if ext not in extension_stats:
                extension_stats[ext] = {"count": 0, "total_size": 0}
            extension_stats[ext]["count"] += 1
            extension_stats[ext]["total_size"] += file_data["size"]
            
            # Size statistics
            size_stats["total_size"] += file_data["size"]
        
        # Generate summary statistics
        processing_time = time.time() - start_time
        
        manifest = {
            "metadata": {
                "generated_at": datetime.now().isoformat(),
                "generator_version": "1.0.0",
                "root_path": str(self.root_path),
                "processing_time_seconds": round(processing_time, 2),
                "total_files_processed": len(all_metadata),
                "excluded_directories": list(self.excluded_dirs)
            },
            "summary_statistics": {
                "total_files": len(all_metadata),
                "total_size": size_stats["total_size"],
                "total_size_human": self.format_bytes(size_stats["total_size"]),
                "categories": {cat: len(files) for cat, files in categorized_files.items()},
                "top_extensions": sorted(
                    extension_stats.items(), 
                    key=lambda x: x[1]["count"], 
                    reverse=True
                )[:20]
            },
            "files": all_metadata,
            "categorized_files": categorized_files,
            "extension_statistics": extension_stats
        }
        
        print(f"✅ Generated manifest for {len(all_metadata)} files in {processing_time:.2f} seconds")
        return manifest
    
    def save_manifest(self, manifest: Dict, output_path: str = "file_manifest.json"):
        """Save manifest to JSON file."""
        output_file = self.root_path / output_path
        
        print(f"Saving manifest to {output_file}")
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)
        
        print(f"✅ Manifest saved: {output_file}")
        return output_file

def main():
    """Main execution function."""
    generator = FileManifestGenerator()
    
    try:
        # Generate manifest
        manifest = generator.generate_manifest(max_workers=8, batch_size=200)
        
        # Save to file
        output_path = generator.save_manifest(manifest)
        
        # Print summary
        stats = manifest["summary_statistics"]
        print(f"\n📊 MANIFEST SUMMARY:")
        print(f"   Total Files: {stats['total_files']:,}")
        print(f"   Total Size: {stats['total_size_human']}")
        print(f"   Categories: {len(stats['categories'])}")
        print(f"   Top Extensions: {', '.join([ext for ext, _ in stats['top_extensions'][:5]])}")
        print(f"   Output: {output_path}")
        
        return True
        
    except Exception as e:
        print(f"❌ Error generating manifest: {e}")
        return False

if __name__ == "__main__":
    success = main()
    exit(0 if success else 1)