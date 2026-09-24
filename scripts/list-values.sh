#!/usr/bin/env bash
# List valid values for a completion "dimension". Used by the zsh/bash
# completion scripts (and handy for scripting).
# Usage: bash scripts/list-values.sh <dimension>
set -euo pipefail

dim="${1:-}"

case "$dim" in
    on-conflict)
        # `medias organize --on-conflict <VALUE>`
        echo "skip"
        echo "suffix"
        echo "overwrite"
        ;;
    shell)
        echo "zsh"
        echo "bash"
        ;;
    dim)
        echo "on-conflict"
        echo "shell"
        echo "dim"
        ;;
    *)
        echo "Unknown dimension: $dim" >&2
        echo "Valid dimensions: on-conflict, shell, dim" >&2
        exit 1
        ;;
esac
