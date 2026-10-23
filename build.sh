#!/bin/bash
# Rebuild the injected library (requires Xcode Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"
xcrun clang -dynamiclib -fobjc-arc -framework Cocoa -arch x86_64 -arch arm64 \
    -o libstcopypath.dylib STCopyPath.m
echo "built: $(pwd)/libstcopypath.dylib"
file libstcopypath.dylib | sed 's/^/  /'
