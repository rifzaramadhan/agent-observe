#!/usr/bin/env bash
set -e
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec bash "$script_dir/lib/install-agents-el.sh" centos7 "$@"
