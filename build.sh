#!/bin/sh
# Builds build/onlymuse. Pass "release" for an optimised build, "helper" for the Swift helper, or "app" for
# build/onlymuse.app with both inside. The helper and the app are signed as "onlymuse local"
# (scripts/make-signing-certificate.sh makes the certificate).
set -eu
cd "$(dirname "$0")"

mode=${1:-debug}

if [ "$mode" = app ]; then
	"$0" release
	"$0" helper

	bundle=build/onlymuse.app
	rm -rf "$bundle"
	mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Helpers" "$bundle/Contents/Resources"
	cp app/Info.plist "$bundle/Contents/"
	cp app/AppIcon.icns "$bundle/Contents/Resources/"
	cp build/onlymuse "$bundle/Contents/MacOS/"
	# In Helpers, not MacOS, the helper has no bundle of its own, so WebKit keeps its sign-ins where they were.
	cp helper/.build/release/onlymuse-helper "$bundle/Contents/Helpers/"

	# The helper keeps its identifier, so Music.app's Automation permission and the Keychain's hold.
	codesign --force --sign "onlymuse local" --identifier dev.mwyndham.onlymuse.helper "$bundle/Contents/Helpers/onlymuse-helper"
	codesign --force --sign "onlymuse local" --identifier dev.mwyndham.onlymuse "$bundle"
	echo "built $bundle"
	exit
fi

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
