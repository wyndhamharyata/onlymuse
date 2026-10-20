#!/bin/sh
# Builds build/onlymuse. Pass "release" for an optimised build.
set -eu
cd "$(dirname "$0")"

mode=${1:-debug}
flags="-collection:om=src -vet-unused -vet-shadowing -strict-style"

if [ "$mode" = release ]; then
	# A single-module build drops the input view's Objective-C methods, so no key ever reaches a text field.
	flags="$flags -o:speed -use-separate-modules"
else
	flags="$flags -debug"
fi

mkdir -p build
odin build src/app -out:build/onlymuse $flags
