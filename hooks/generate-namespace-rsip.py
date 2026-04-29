#!/usr/bin/env python3
"""Generate ResourceSetInputProvider from kubernetes/apps/*/ directories."""

import sys
from pathlib import Path

APPS_DIR = Path("kubernetes/apps")
TEMPLATE_FILE = Path("kubernetes/flux/meta/cluster-apps-rsip.yaml.tmpl")
OUTPUT_FILE = Path("kubernetes/flux/meta/cluster-apps-rsip.yaml")


def main():
    namespaces = sorted(
        [
            d.name
            for d in APPS_DIR.iterdir()
            if d.is_dir() and not d.name.startswith(".")
        ]
    )

    with open(TEMPLATE_FILE, "r") as f:
        template = f.read()

    entries = "\n".join([f"      - namespace: {ns}" for ns in namespaces])
    content = template.replace("GENERATED_INPUTS_MARKER", entries)

    with open(OUTPUT_FILE, "w") as f:
        f.write(content)

    print(
        f"Generated {OUTPUT_FILE} with {len(namespaces)} namespaces: {', '.join(namespaces)}"
    )


if __name__ == "__main__":
    main()
