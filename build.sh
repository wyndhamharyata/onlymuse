#!/bin/sh
# Builds build/onlymuse. Pass "release" for an optimised build, or "helper" for the Swift helper,
# signed as "onlymuse local" (scripts/make-signing-certificate.sh makes the certificate).
set -eu
cd "$(dirname "$0")"

mode=${1:-debug}

if [ "$mode" = helper ]; then
	swift build -c release --package-path helper
	codesign --force --sign "onlymuse local" --identifier dev.mwyndham.onlymuse.helper helper/.build/release/onlymuse-helper
	exit
fi
flags="-collection:om=src -vet-unused -vet-shadowing -strict-style"

if [ "$mode" = release ]; then
	# A single-module build drops the input view's Objective-C methods, so no key ever reaches a text field.
	flags="$flags -o:speed -use-separate-modules"
else
	flags="$flags -debug"
fi

mkdir -p build
odin build src/app -out:build/onlymuse $flags
