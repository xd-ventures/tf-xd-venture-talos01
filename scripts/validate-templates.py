#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

"""Validate .tftpl template files produce valid multi-document YAML.

Renders Terraform template variables (${...}) with dummy values, then parses
the result as multi-document YAML to catch structural errors before they get
baked into the OVH config drive.

Also scans for literal escape sequences (\n, \t) in non-shell contexts that
could be corrupted by OVH cleartext processing (defense in depth — we use
base64encode() now, but this catches regressions).

Usage:
  python3 scripts/validate-templates.py [templates/*.tftpl ...]
  # No arguments = validate all templates/*.tftpl files

Exit codes:
  0 - all templates valid
  1 - validation errors found
"""

from __future__ import annotations

import glob
import re
import sys

import yaml


def render_template(content: str) -> str:
    """Replace Terraform ${...} interpolations with dummy strings.

    Handles:
    - ${var} → PLACEHOLDER (Terraform variable)
    - $${var} → ${var} (Terraform-escaped, becomes shell variable — leave as-is)
    """
    # First, convert Terraform escapes ($${ → ${) so they don't match the next regex
    rendered = content.replace("$${", "\x00SHELL\x00")
    # Replace Terraform interpolations with a safe dummy value
    rendered = re.sub(r"\$\{[^}]+\}", "PLACEHOLDER", rendered)
    # Restore shell variable references
    rendered = rendered.replace("\x00SHELL\x00", "${")
    return rendered


def check_escape_sequences(content: str, filepath: str) -> list[str]:
    """Scan for literal \\n, \\t outside of shell script blocks.

    Inside YAML literal block scalars (command: | sections), escape sequences
    are expected (they're shell code). Outside, they may indicate content that
    would be corrupted by OVH cleartext processing.
    """
    errors = []
    in_block_scalar = False

    for lineno, line in enumerate(content.splitlines(), 1):
        stripped = line.strip()

        # Detect start/end of YAML literal block scalars (command blocks)
        if re.match(r"^-\s*\|", stripped) or stripped.endswith("|"):
            in_block_scalar = True
            continue

        # Block scalar ends when indentation returns to the key level
        # (simplified: any line starting with '- ' or a YAML key resets it)
        if in_block_scalar and stripped and not line.startswith(" " * 8):
            if re.match(r"^[\w-]", stripped) or re.match(r"^\s*-\s+\w", stripped):
                in_block_scalar = False

        if not in_block_scalar:
            # Skip comments
            if stripped.lstrip().startswith("#"):
                continue
            # Check for literal \n or \t outside quoted strings
            # Remove single- and double-quoted segments before scanning
            unquoted = re.sub(r'"[^"]*"', '', re.sub(r"'[^']*'", '', stripped))
            if re.search(r'(?<!\\)\\[nt]', unquoted):
                errors.append(f"{filepath}:{lineno}: literal escape sequence found: {stripped}")

    return errors


def validate_template(filepath: str) -> list[str]:
    """Validate a single template file. Returns list of error messages."""
    errors = []

    with open(filepath) as f:
        content = f.read()

    # Render template variables
    rendered = render_template(content)

    # Parse as multi-document YAML
    try:
        docs = list(yaml.safe_load_all(rendered))
        if not docs or all(d is None for d in docs):
            errors.append(f"{filepath}: no YAML documents found")
    except yaml.YAMLError as e:
        errors.append(f"{filepath}: YAML parse error: {e}")

    # Check for escape sequences outside shell blocks
    errors.extend(check_escape_sequences(content, filepath))

    return errors


def main() -> None:
    files = sys.argv[1:] if len(sys.argv) > 1 else sorted(glob.glob("templates/*.tftpl"))

    if not files:
        print("No template files found")
        return

    all_errors = []
    for filepath in files:
        if not filepath.endswith(".tftpl"):
            continue
        errors = validate_template(filepath)
        if errors:
            all_errors.extend(errors)
        else:
            print(f"  {filepath}: ok")

    if all_errors:
        print("\nValidation errors:")
        for error in all_errors:
            print(f"  {error}")
        sys.exit(1)

    print(f"\nAll {len(files)} template(s) valid.")


if __name__ == "__main__":
    main()
