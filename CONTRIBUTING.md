# Contributing to Long-Home

Thank you for your interest in contributing to Long-Home! This document provides guidelines and information for contributors.

## Table of Contents

- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [How to Contribute](#how-to-contribute)
- [Coding Standards](#coding-standards)
- [Commit Guidelines](#commit-guidelines)
- [Pull Request Process](#pull-request-process)
- [Reporting Issues](#reporting-issues)

## Getting Started

1. Fork the repository on GitHub
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/Long-Home.git
   cd Long-Home
   ```
3. Add the upstream repository as a remote:
   ```bash
   git remote add upstream https://github.com/kase1111-hash/Long-Home.git
   ```

## Development Setup

### Prerequisites

- [Godot Engine 4.2+](https://godotengine.org/download)
- Git
- Python 3.x (for running tests)

### Setting Up the Project

1. Open the project in Godot:
   ```bash
   godot --editor project.godot
   ```

2. Run the test suite to verify everything works:
   ```bash
   python tests/test_gdscript_validation.py
   ```

## How to Contribute

### Types of Contributions

- **Bug Fixes**: Fix issues reported in the issue tracker
- **New Features**: Implement features from the roadmap or propose new ones
- **Documentation**: Improve docs, add examples, fix typos
- **Tests**: Add or improve test coverage
- **Performance**: Optimize existing systems

### Before You Start

1. Check the [issue tracker](https://github.com/kase1111-hash/Long-Home/issues) to see if someone is already working on it
2. For new features, open an issue first to discuss the approach
3. Review the [SPEC-SHEET.md](SPEC-SHEET.md) and [PROGRAMMING-ROADMAP.md](PROGRAMMING-ROADMAP.md) to understand the architecture

## Coding Standards

### GDScript Style Guide

Follow the [official GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html) with these additions:

1. **Naming Conventions**:
   - Classes: `PascalCase`
   - Functions/methods: `snake_case`
   - Variables: `snake_case`
   - Constants: `SCREAMING_SNAKE_CASE`
   - Signals: `snake_case` (verb in past tense, e.g., `player_moved`)

2. **File Organization**:
   ```gdscript
   class_name ClassName
   extends BaseClass

   # Signals
   signal something_happened

   # Constants
   const MAX_VALUE := 100

   # Exported variables
   @export var exported_var: int = 0

   # Public variables
   var public_var: String = ""

   # Private variables (prefix with _)
   var _private_var: float = 0.0

   # Lifecycle methods
   func _ready() -> void:
       pass

   func _process(delta: float) -> void:
       pass

   # Public methods
   func public_method() -> void:
       pass

   # Private methods
   func _private_method() -> void:
       pass
   ```

3. **Type Hints**: Always use type hints for function parameters and return values

4. **Comments**:
   - Use comments to explain *why*, not *what*
   - Document public APIs with docstrings

### Architecture Guidelines

- Use the **Event Bus** (`EventBus`) for cross-system communication
- Register services with the **Service Locator** (`ServiceLocator`)
- Follow the existing state machine patterns for new states
- Keep UI diegetic - avoid traditional HUD elements

## Commit Guidelines

### Commit Message Format

```
<type>: <short summary>

<optional body>

<optional footer>
```

### Types

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, no logic change)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

### Examples

```
feat: Add crevasse detection system

Implements basic crevasse detection using terrain analysis.
Integrates with the risk detection system.

Closes #42
```

```
fix: Resolve sliding control loss at steep angles

Players were losing control too quickly on slopes > 40 degrees.
Adjusted the control degradation curve.
```

## Pull Request Process

1. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** following the coding standards

3. **Test your changes**:
   - Run the test suite
   - Test in-game manually
   - Verify no regressions in related systems

4. **Update documentation** if needed:
   - Update relevant sections in SPEC-SHEET.md
   - Update PROGRAMMING-ROADMAP.md if adding new systems
   - Add inline documentation for complex logic

5. **Submit the PR**:
   - Fill out the PR template completely
   - Link related issues
   - Request review from maintainers

6. **Address review feedback**:
   - Make requested changes
   - Push updates to the same branch
   - Re-request review when ready

### PR Requirements

- [ ] Code follows the style guidelines
- [ ] Tests pass locally
- [ ] Documentation updated (if applicable)
- [ ] No merge conflicts with main branch
- [ ] Meaningful commit messages

## Reporting Issues

### Bug Reports

When reporting bugs, please include:

1. **Summary**: Clear, concise description
2. **Steps to Reproduce**: Numbered steps to recreate the issue
3. **Expected Behavior**: What should happen
4. **Actual Behavior**: What actually happens
5. **Environment**: Godot version, OS, hardware specs
6. **Screenshots/Videos**: If applicable

### Feature Requests

When requesting features:

1. **Problem Statement**: What problem does this solve?
2. **Proposed Solution**: How should it work?
3. **Alternatives**: Other approaches considered
4. **Context**: How does this fit with the game's philosophy?

## Questions?

If you have questions about contributing, feel free to:

- Open a discussion on GitHub
- Review existing issues and PRs for context
- Check the documentation in SPEC-SHEET.md and PROGRAMMING-ROADMAP.md

Thank you for contributing to Long-Home!
