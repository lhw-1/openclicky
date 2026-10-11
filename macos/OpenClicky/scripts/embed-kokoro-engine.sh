#!/usr/bin/env bash
# Puts Kokoro's engine (sherpa-onnx's C library and ONNX Runtime, universal) inside the app, signed
# with the app's own identity, so it loads with library validation on (KokoroEngine.swift).
#
# Run by the OpenClicky target's "Embed Kokoro engine" build phase. The release archive is fetched
# once into ThirdParty/ (git-ignored) and checked against a pinned SHA-256; the version must match
# OpenClicky/Kokoro/sherpa-onnx-c-api.h. release.sh re-signs the two libraries with Developer ID.
set -euo pipefail

VERSION="1.13.8"
ARCHIVE="sherpa-onnx-v${VERSION}-osx-universal2-shared-lib.tar.bz2"
SHA256="c1cca5b4a1867543e27d42fbea513983e73f629d0aa53b43b51555a71d2108d9"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${ARCHIVE}"
LIBRARIES=(libsherpa-onnx-c-api.dylib libonnxruntime.dylib)

project_dir="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cache="$project_dir/ThirdParty/sherpa-onnx-$VERSION"

if [[ ! -f "$cache/${LIBRARIES[0]}" || ! -f "$cache/${LIBRARIES[1]}" ]]; then
  echo "embed-kokoro-engine: fetching sherpa-onnx $VERSION"
  mkdir -p "$cache"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 4 -o "$tmp/$ARCHIVE" "$URL"
  actual="$(shasum -a 256 "$tmp/$ARCHIVE" | awk '{print $1}')"
  if [[ "$actual" != "$SHA256" ]]; then
    echo "error: $ARCHIVE checksum is $actual, expected $SHA256" >&2
    exit 1
  fi
  tar -xjf "$tmp/$ARCHIVE" -C "$tmp"
  for library in "${LIBRARIES[@]}"; do cp "$tmp/sherpa-onnx-v${VERSION}-osx-universal2-shared-lib/lib/$library" "$cache/"; done
fi

# Outside a build (run by hand) only the cache is filled.
[[ -n "${TARGET_BUILD_DIR:-}" ]] || exit 0

destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$destination"
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -n "$identity" ]] || identity="-"
for library in "${LIBRARIES[@]}"; do
  cp -f "$cache/$library" "$destination/$library"
  chmod 755 "$destination/$library"
  codesign --force --options runtime --timestamp=none --sign "$identity" "$destination/$library"
done
