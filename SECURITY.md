# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

We take security seriously in Long-Home. If you discover a security vulnerability, please report it responsibly.

### How to Report

1. **Do NOT** open a public GitHub issue for security vulnerabilities
2. Send a detailed report to the repository maintainers via GitHub's private vulnerability reporting feature
3. Include as much information as possible:
   - Type of vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

### What to Expect

- **Acknowledgment**: We will acknowledge receipt within 48 hours
- **Assessment**: We will assess the vulnerability and its impact
- **Updates**: We will keep you informed of our progress
- **Resolution**: We aim to resolve critical issues within 30 days
- **Credit**: With your permission, we will credit you in the release notes

### Scope

Security concerns for Long-Home may include:

- **Save File Manipulation**: Vulnerabilities in the save/load system that could allow arbitrary code execution
- **Network Exploits**: Issues in the OBS/streaming integration
- **Mod/Plugin Security**: If modding support is added, vulnerabilities in that system
- **Data Exposure**: Unintended exposure of user data or system information

### Out of Scope

The following are generally not considered security vulnerabilities:

- Gameplay exploits (e.g., finding unintended shortcuts on mountains)
- Visual glitches or graphical artifacts
- Game balance issues
- Crashes that don't involve security implications

## Security Best Practices for Contributors

When contributing to Long-Home:

1. **Validate Input**: Always validate and sanitize external data (save files, mountain manifests, etc.)
2. **Avoid Arbitrary Code Execution**: Never use `eval()` or similar constructs on user data
3. **File Path Safety**: Validate file paths to prevent directory traversal attacks
4. **Resource Limits**: Implement appropriate limits to prevent resource exhaustion

## Third-Party Dependencies

Long-Home is built on:

- **Godot Engine 4.2**: Keep updated to receive security patches
- Monitor Godot's security advisories at [godotengine.org](https://godotengine.org)

Thank you for helping keep Long-Home secure!
