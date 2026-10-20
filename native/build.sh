#!/bin/sh
# Builds build/onlymuse. Pass "release" for an optimised build.
set -eu
cd "$(dirname "$0")"

mode=${1:-debug}
flags="-collection:om=src -vet-unused -vet-shadowing -strict-style"

if [ "$mode" = release ]; then
	flags="$flags -o:speed"
else
	flags="$flags -debug"
fi

mkdir -p build
odin build src/app -out:build/onlymuse $flags
