#!/usr/bin/env python3
"""Generate ResourceSet from kubernetes/apps/*/ directories."""

from pathlib import Path

APPS_DIR = Path("kubernetes/apps")
TEMPLATE_FILE = Path("kubernetes/flux/cluster/resourceset.yaml.tmpl")
OUTPUT_FILE = Path("kubernetes/flux/cluster/resourceset.yaml")


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

    entries = "\n".join([f"    - namespace: {ns}" for ns in namespaces])
    content = template.replace("GENERATED_INPUTS_MARKER", entries)

    with open(OUTPUT_FILE, "w") as f:
        f.write(content)

    print(
        f"Generated {OUTPUT_FILE} with {len(namespaces)} namespaces: {', '.join(namespaces)}"
    )


if __name__ == "__main__":
    main()
