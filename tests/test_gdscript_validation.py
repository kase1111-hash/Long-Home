#!/usr/bin/env python3
"""
GDScript Static Analysis Test Suite for Long-Home
Validates syntax, references, signals, and dependencies without Godot runtime.
"""

import os
import re
import sys
from pathlib import Path
from dataclasses import dataclass, field
from typing import Dict, List, Set, Tuple, Optional
from collections import defaultdict

# Project root
PROJECT_ROOT = Path(__file__).parent.parent
SRC_DIR = PROJECT_ROOT / "src"

@dataclass
class GDScriptFile:
    path: Path
    content: str
    class_name: Optional[str] = None
    extends: Optional[str] = None
    preloads: List[str] = field(default_factory=list)
    signals: List[str] = field(default_factory=list)
    signal_emissions: List[str] = field(default_factory=list)
    functions: List[str] = field(default_factory=list)
    enums_used: List[str] = field(default_factory=list)
    local_enums: Dict[str, Set[str]] = field(default_factory=dict)  # Local enum definitions
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)

class GDScriptValidator:
    def __init__(self, src_dir: Path):
        self.src_dir = src_dir
        self.files: Dict[Path, GDScriptFile] = {}
        self.class_names: Dict[str, Path] = {}
        self.all_signals: Dict[str, Path] = {}
        self.errors: List[Tuple[Path, str]] = []
        self.warnings: List[Tuple[Path, str]] = []

    def discover_files(self) -> List[Path]:
        """Find all .gd files in the source directory."""
        return list(self.src_dir.rglob("*.gd"))

    def parse_file(self, path: Path) -> GDScriptFile:
        """Parse a GDScript file and extract metadata."""
        content = path.read_text()
        gd_file = GDScriptFile(path=path, content=content)

        lines = content.split('\n')
        in_multiline_string = False
        brace_depth = 0
        paren_depth = 0
        current_local_enum = None

        for line_num, line in enumerate(lines, 1):
            stripped = line.strip()

            # Skip comments and empty lines
            if stripped.startswith('#') or not stripped:
                continue

            # Track string literals to avoid false positives
            if '"""' in stripped or "'''" in stripped:
                in_multiline_string = not in_multiline_string
                continue
            if in_multiline_string:
                continue

            # class_name declaration
            match = re.match(r'^class_name\s+(\w+)', stripped)
            if match:
                gd_file.class_name = match.group(1)

            # extends declaration
            match = re.match(r'^extends\s+(["\w/.]+)', stripped)
            if match:
                gd_file.extends = match.group(1).strip('"')

            # preload statements
            for match in re.finditer(r'preload\s*\(\s*["\']([^"\']+)["\']\s*\)', stripped):
                gd_file.preloads.append(match.group(1))

            # signal declarations
            match = re.match(r'^signal\s+(\w+)', stripped)
            if match:
                gd_file.signals.append(match.group(1))

            # Local enum declarations
            match = re.match(r'^enum\s+(\w+)\s*\{?', stripped)
            if match:
                current_local_enum = match.group(1)
                gd_file.local_enums[current_local_enum] = set()

            # Local enum values
            if current_local_enum is not None:
                if '}' in stripped:
                    # Extract values before closing brace
                    for val_match in re.finditer(r'(\w+)\s*[,=}]', stripped):
                        val = val_match.group(1)
                        if val and val != current_local_enum:
                            gd_file.local_enums[current_local_enum].add(val)
                    current_local_enum = None
                else:
                    # Extract values from this line
                    for val_match in re.finditer(r'(\w+)\s*[,=]?', stripped):
                        val = val_match.group(1)
                        if val and val != 'enum' and val != current_local_enum:
                            gd_file.local_enums[current_local_enum].add(val)

            # signal emissions (emit_signal or .emit())
            for match in re.finditer(r'emit_signal\s*\(\s*["\'](\w+)["\']', stripped):
                gd_file.signal_emissions.append(match.group(1))
            for match in re.finditer(r'(\w+)\.emit\s*\(', stripped):
                gd_file.signal_emissions.append(match.group(1))

            # function declarations
            match = re.match(r'^func\s+(\w+)\s*\(', stripped)
            if match:
                gd_file.functions.append(match.group(1))

            # GameEnums usage - exclude method calls like .keys(), .values()
            for match in re.finditer(r'GameEnums\.(\w+)\.(\w+)', stripped):
                enum_type = match.group(1)
                enum_value = match.group(2)
                # Skip method calls like .keys(), .values(), .size(), .get()
                if enum_value not in ('keys', 'values', 'size', 'has', 'find_key', 'get'):
                    # Skip constants (all uppercase names like SLOPE_THRESHOLDS)
                    if not enum_type.isupper():
                        gd_file.enums_used.append(f"{enum_type}.{enum_value}")

            # Basic syntax checks
            # Unmatched braces/parens (simple check)
            brace_depth += stripped.count('{') - stripped.count('}')
            paren_depth += stripped.count('(') - stripped.count(')')

            # Check for common issues
            if 'var ' in stripped and '=' not in stripped and ':' not in stripped:
                if not stripped.endswith(':') and 'func' not in stripped:
                    # Uninitialized variable without type hint
                    pass  # This is actually valid in GDScript

        # Final brace check
        if brace_depth != 0:
            gd_file.errors.append(f"Unbalanced braces (depth: {brace_depth})")
        if paren_depth != 0:
            gd_file.errors.append(f"Unbalanced parentheses (depth: {paren_depth})")

        return gd_file

    def validate_preloads(self, gd_file: GDScriptFile):
        """Validate that preloaded files exist."""
        for preload_path in gd_file.preloads:
            # Convert res:// path to filesystem path
            if preload_path.startswith("res://"):
                rel_path = preload_path[6:]  # Remove "res://"
                full_path = PROJECT_ROOT / rel_path
                if not full_path.exists():
                    gd_file.errors.append(f"Preload file not found: {preload_path}")

    def validate_extends(self, gd_file: GDScriptFile):
        """Validate extends declarations."""
        if not gd_file.extends:
            return

        extends = gd_file.extends

        # Built-in types are always valid
        builtin_types = {
            'Node', 'Node2D', 'Node3D', 'Control', 'Resource', 'RefCounted',
            'CharacterBody3D', 'RigidBody3D', 'StaticBody3D', 'Area3D',
            'Camera3D', 'MeshInstance3D', 'CollisionShape3D',
            'Object', 'Reference', 'Spatial'
        }

        if extends in builtin_types:
            return

        # Check if it's a res:// path
        if extends.startswith("res://"):
            rel_path = extends[6:]
            full_path = PROJECT_ROOT / rel_path
            if not full_path.exists():
                gd_file.errors.append(f"Extended file not found: {extends}")
            return

        # Check if it's a known class_name
        if extends not in self.class_names and extends not in builtin_types:
            gd_file.warnings.append(f"Extended class not verified: {extends}")

    def validate_signals(self, gd_file: GDScriptFile):
        """Check that emitted signals are declared somewhere."""
        declared_signals = set(gd_file.signals)

        for emission in gd_file.signal_emissions:
            if emission not in declared_signals and emission not in self.all_signals:
                # Could be EventBus signal or dynamic
                if not emission.startswith("_"):
                    gd_file.warnings.append(f"Signal '{emission}' emitted but not declared locally")

    def validate_enums(self, gd_file: GDScriptFile):
        """Validate GameEnums usage against defined enums."""
        # Parse enums.gd to get valid enums
        enums_file = self.src_dir / "core" / "enums.gd"
        if not enums_file.exists():
            return

        enums_content = enums_file.read_text()
        defined_enums: Dict[str, Set[str]] = {}

        current_enum = None
        for line in enums_content.split('\n'):
            stripped = line.strip()

            # Enum declaration
            match = re.match(r'^enum\s+(\w+)\s*\{?', stripped)
            if match:
                current_enum = match.group(1)
                defined_enums[current_enum] = set()
                continue

            # Enum values
            if current_enum and stripped and not stripped.startswith('#'):
                if stripped == '}' or '}' in stripped:
                    # Extract any values before closing brace
                    for val_match in re.finditer(r'(\w+)\s*[,=}]', stripped):
                        val = val_match.group(1)
                        if val and val not in ['enum', current_enum]:
                            defined_enums[current_enum].add(val)
                    current_enum = None
                    continue
                # Extract enum value names
                for val_match in re.finditer(r'(\w+)\s*[,=}]?', stripped):
                    val = val_match.group(1)
                    if val and val not in ['enum', current_enum]:
                        defined_enums[current_enum].add(val)

        # Validate usage
        for enum_usage in gd_file.enums_used:
            parts = enum_usage.split('.')
            if len(parts) == 2:
                enum_name, enum_value = parts

                # Skip if this is a local enum in this file
                if enum_name in gd_file.local_enums:
                    continue

                if enum_name not in defined_enums:
                    gd_file.errors.append(f"Unknown enum type: GameEnums.{enum_name}")
                elif enum_value not in defined_enums[enum_name]:
                    gd_file.errors.append(f"Unknown enum value: GameEnums.{enum_usage}")

    def validate_required_patterns(self, gd_file: GDScriptFile):
        """Check for required patterns in specific file types."""
        filename = gd_file.path.name

        # Services should have initialize() or _ready()
        if filename.endswith("_service.gd"):
            has_init = "_ready" in gd_file.functions or "initialize" in gd_file.functions
            if not has_init:
                gd_file.warnings.append("Service missing _ready() or initialize() function")

        # Managers should extend RefCounted or Node
        if filename.endswith("_manager.gd"):
            valid_extends = ['RefCounted', 'Node', 'Node3D']
            if gd_file.extends and gd_file.extends not in valid_extends:
                gd_file.warnings.append(f"Manager has unusual base class: {gd_file.extends}")

    def run_validation(self) -> bool:
        """Run full validation and return success status."""
        print("=" * 60)
        print("GDScript Static Analysis - Long Home")
        print("=" * 60)
        print()

        # Discover files
        files = self.discover_files()
        print(f"Found {len(files)} GDScript files")
        print()

        # Parse all files first
        print("Parsing files...")
        for path in files:
            gd_file = self.parse_file(path)
            self.files[path] = gd_file

            # Register class names
            if gd_file.class_name:
                self.class_names[gd_file.class_name] = path

            # Register signals
            for signal in gd_file.signals:
                self.all_signals[signal] = path

        print(f"  - Found {len(self.class_names)} class_name declarations")
        print(f"  - Found {len(self.all_signals)} signal declarations")
        print()

        # Run validations
        print("Running validations...")
        for path, gd_file in self.files.items():
            self.validate_preloads(gd_file)
            self.validate_extends(gd_file)
            self.validate_signals(gd_file)
            self.validate_enums(gd_file)
            self.validate_required_patterns(gd_file)

            # Collect errors and warnings
            for error in gd_file.errors:
                self.errors.append((path, error))
            for warning in gd_file.warnings:
                self.warnings.append((path, warning))

        # Report results
        print()
        print("=" * 60)
        print("VALIDATION RESULTS")
        print("=" * 60)
        print()

        # File summary
        print("FILE SUMMARY:")
        print("-" * 40)
        for path, gd_file in sorted(self.files.items()):
            rel_path = path.relative_to(PROJECT_ROOT)
            status = "✓" if not gd_file.errors else "✗"
            extras = []
            if gd_file.class_name:
                extras.append(f"class: {gd_file.class_name}")
            if gd_file.signals:
                extras.append(f"signals: {len(gd_file.signals)}")
            if gd_file.functions:
                extras.append(f"funcs: {len(gd_file.functions)}")
            extra_str = f" ({', '.join(extras)})" if extras else ""
            print(f"  {status} {rel_path}{extra_str}")

        print()

        # Errors
        if self.errors:
            print("ERRORS:")
            print("-" * 40)
            for path, error in self.errors:
                rel_path = path.relative_to(PROJECT_ROOT)
                print(f"  ✗ {rel_path}: {error}")
            print()
        else:
            print("ERRORS: None")
            print()

        # Warnings
        if self.warnings:
            print("WARNINGS:")
            print("-" * 40)
            for path, warning in self.warnings:
                rel_path = path.relative_to(PROJECT_ROOT)
                print(f"  ⚠ {rel_path}: {warning}")
            print()
        else:
            print("WARNINGS: None")
            print()

        # Summary
        print("=" * 60)
        print(f"SUMMARY: {len(files)} files, {len(self.errors)} errors, {len(self.warnings)} warnings")
        print("=" * 60)

        return len(self.errors) == 0


class DependencyAnalyzer:
    """Analyze and visualize system dependencies."""

    def __init__(self, files: Dict[Path, GDScriptFile]):
        self.files = files

    def build_dependency_graph(self) -> Dict[str, Set[str]]:
        """Build a graph of file dependencies."""
        graph: Dict[str, Set[str]] = defaultdict(set)

        for path, gd_file in self.files.items():
            source = str(path.relative_to(PROJECT_ROOT))

            # Add preload dependencies
            for preload in gd_file.preloads:
                if preload.startswith("res://"):
                    target = preload[6:]
                    graph[source].add(target)

        return graph

    def analyze_systems(self) -> Dict[str, List[str]]:
        """Group files by system."""
        systems: Dict[str, List[str]] = defaultdict(list)

        for path in self.files:
            rel_path = path.relative_to(PROJECT_ROOT)
            parts = rel_path.parts

            if len(parts) >= 3 and parts[0] == "src" and parts[1] == "systems":
                system_name = parts[2]
                systems[system_name].append(str(rel_path))

        return systems

    def print_analysis(self):
        """Print dependency analysis."""
        print()
        print("=" * 60)
        print("SYSTEM ARCHITECTURE ANALYSIS")
        print("=" * 60)
        print()

        systems = self.analyze_systems()
        print(f"Found {len(systems)} systems:")
        print()

        for system_name, files in sorted(systems.items()):
            print(f"  {system_name.upper()}:")
            for f in sorted(files):
                print(f"    - {Path(f).name}")
        print()

        # Dependency graph
        graph = self.build_dependency_graph()
        if graph:
            print("CROSS-SYSTEM DEPENDENCIES:")
            print("-" * 40)
            for source, targets in sorted(graph.items()):
                if targets:
                    print(f"  {source}:")
                    for target in sorted(targets):
                        print(f"    → {target}")


class IntegrationValidator:
    """Validate system integration points."""

    def __init__(self, src_dir: Path):
        self.src_dir = src_dir
        self.errors: List[str] = []

    def validate_autoloads(self) -> bool:
        """Validate autoload scripts exist and are properly structured."""
        print()
        print("AUTOLOAD VALIDATION:")
        print("-" * 40)

        project_file = PROJECT_ROOT / "project.godot"
        if not project_file.exists():
            print("  ✗ project.godot not found")
            return False

        content = project_file.read_text()

        # Extract autoloads
        autoload_section = False
        autoloads = []

        for line in content.split('\n'):
            if line.strip() == "[autoload]":
                autoload_section = True
                continue
            if autoload_section:
                if line.startswith('['):
                    break
                match = re.match(r'(\w+)="\*?res://(.+)"', line.strip())
                if match:
                    autoloads.append((match.group(1), match.group(2)))

        all_valid = True
        for name, path in autoloads:
            full_path = PROJECT_ROOT / path
            if full_path.exists():
                print(f"  ✓ {name} → {path}")
            else:
                print(f"  ✗ {name} → {path} (NOT FOUND)")
                all_valid = False

        return all_valid

    def validate_service_locator_usage(self) -> bool:
        """Check that services register with ServiceLocator."""
        print()
        print("SERVICE LOCATOR USAGE:")
        print("-" * 40)

        services = list(self.src_dir.rglob("*_service.gd"))

        for service_path in services:
            content = service_path.read_text()
            rel_path = service_path.relative_to(PROJECT_ROOT)

            # Check for ServiceLocator registration
            has_register = "ServiceLocator.register" in content or "ServiceLocator.provide" in content
            has_ready = "_ready" in content

            if has_register:
                print(f"  ✓ {rel_path.name} registers with ServiceLocator")
            elif has_ready:
                print(f"  ⚠ {rel_path.name} has _ready but no ServiceLocator registration")
            else:
                print(f"  - {rel_path.name} (standalone)")

        return True

    def validate_event_bus_signals(self) -> bool:
        """Validate EventBus signal usage."""
        print()
        print("EVENT BUS VALIDATION:")
        print("-" * 40)

        event_bus_path = self.src_dir / "core" / "event_bus.gd"
        if not event_bus_path.exists():
            print("  ✗ event_bus.gd not found")
            return False

        content = event_bus_path.read_text()

        # Extract signals
        signals = []
        for match in re.finditer(r'^signal\s+(\w+)', content, re.MULTILINE):
            signals.append(match.group(1))

        print(f"  EventBus declares {len(signals)} signals:")
        for sig in sorted(signals):
            print(f"    - {sig}")

        # Check usage across codebase
        print()
        print("  Signal usage across codebase:")
        signal_usage: Dict[str, int] = defaultdict(int)

        for gd_file in self.src_dir.rglob("*.gd"):
            if gd_file.name == "event_bus.gd":
                continue
            file_content = gd_file.read_text()

            for sig in signals:
                if f"EventBus.{sig}" in file_content:
                    signal_usage[sig] += 1

        for sig in sorted(signals):
            count = signal_usage.get(sig, 0)
            status = "✓" if count > 0 else "⚠"
            print(f"    {status} {sig}: {count} usages")

        return True


def main():
    """Run all validations."""
    print("\n" + "=" * 60)
    print("LONG-HOME END-TO-END VALIDATION")
    print("=" * 60 + "\n")

    # Basic validation
    validator = GDScriptValidator(SRC_DIR)
    syntax_ok = validator.run_validation()

    # Dependency analysis
    analyzer = DependencyAnalyzer(validator.files)
    analyzer.print_analysis()

    # Integration validation
    integration = IntegrationValidator(SRC_DIR)
    autoload_ok = integration.validate_autoloads()
    integration.validate_service_locator_usage()
    integration.validate_event_bus_signals()

    # Final result
    print()
    print("=" * 60)
    if syntax_ok and autoload_ok:
        print("ALL VALIDATIONS PASSED ✓")
        return 0
    else:
        print("VALIDATION FAILED ✗")
        return 1


if __name__ == "__main__":
    sys.exit(main())
