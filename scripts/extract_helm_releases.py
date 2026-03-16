#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki
"""Extract helm_release resources from OpenTofu .tf files.

Outputs a JSON array of Helm chart references discovered in the codebase.
Handles version set inline or via variable reference (with default lookup).

Usage:
    python3 scripts/extract_helm_releases.py [tf_dir]
    python3 scripts/extract_helm_releases.py . | jq .
"""

import glob
import json
import re
import sys


def extract_helm_releases(tf_dir: str = ".") -> list[dict]:
    """Parse all .tf files and extract helm_release metadata."""
    releases = []
    variables = _extract_variable_defaults(tf_dir)

    for tf_file in sorted(glob.glob(f"{tf_dir}/**/*.tf", recursive=True)):
        with open(tf_file) as f:
            content = f.read()

        for match in re.finditer(
            r'resource\s+"helm_release"\s+"(\w+)"\s*\{(.*?)\n\}',
            content,
            re.DOTALL,
        ):
            resource_name = match.group(1)
            body = match.group(2)

            name = _extract_string(body, "name")
            repository = _extract_string(body, "repository")
            chart = _extract_string(body, "chart")
            version = _extract_version(body, variables)

            if chart and repository and version:
                releases.append({
                    "resource": resource_name,
                    "name": name or resource_name,
                    "repository": repository,
                    "chart": chart,
                    "version": version,
                    "source_file": tf_file,
                })

    return releases


def extract_inline_images(tf_dir: str = ".") -> list[dict]:
    """Extract container image references from .tftpl template files.

    Resolves Terraform variable interpolations using variable defaults.
    """
    variables = _extract_variable_defaults(tf_dir)
    images = []

    for tftpl in sorted(glob.glob(f"{tf_dir}/**/templates/*.tftpl", recursive=True)):
        with open(tftpl) as f:
            content = f.read()

        for match in re.finditer(r"image:\s*(\S+)", content):
            raw = match.group(1).strip("\"'")
            resolved = _resolve_interpolations(raw, variables)
            if resolved and "${" not in resolved:
                images.append({
                    "image": resolved,
                    "source_file": tftpl,
                })

    # Deduplicate by image
    seen = set()
    unique = []
    for img in images:
        if img["image"] not in seen:
            seen.add(img["image"])
            unique.append(img)
    return unique


def _extract_string(body: str, key: str) -> str | None:
    """Extract a simple string assignment: key = "value"."""
    m = re.search(rf'{key}\s*=\s*"([^"]+)"', body)
    return m.group(1) if m else None


def _extract_version(body: str, variables: dict) -> str | None:
    """Extract version — either literal string or var.xxx reference."""
    # Try unquoted variable reference: version = var.argocd_chart_version
    m = re.search(r"version\s*=\s*var\.(\w+)", body)
    if m:
        return variables.get(m.group(1))

    # Try literal string: version = "9.4.11"
    return _extract_string(body, "version")


def _extract_variable_defaults(tf_dir: str) -> dict:
    """Extract variable default values from all .tf files."""
    defaults = {}
    for tf_file in sorted(glob.glob(f"{tf_dir}/**/*.tf", recursive=True)):
        with open(tf_file) as f:
            content = f.read()

        for m in re.finditer(
            r'variable\s+"(\w+)"\s*\{(.*?)\n\}', content, re.DOTALL
        ):
            var_name = m.group(1)
            var_body = m.group(2)
            default = _extract_string(var_body, "default")
            if default:
                defaults[var_name] = default
    return defaults


def _resolve_interpolations(raw: str, variables: dict) -> str:
    """Replace ${var_name} with variable default values."""
    def replacer(m):
        var_name = m.group(1)
        return variables.get(var_name, m.group(0))

    return re.sub(r"\$\{(\w+)\}", replacer, raw)


if __name__ == "__main__":
    tf_dir = sys.argv[1] if len(sys.argv) > 1 else "."

    result = {
        "helm_releases": extract_helm_releases(tf_dir),
        "inline_images": extract_inline_images(tf_dir),
    }

    json.dump(result, sys.stdout, indent=2)
    print()
