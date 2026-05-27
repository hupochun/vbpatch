#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$ROOT_DIR/dist"
VERSION="$(awk -F= '/^version=/{print $2}' "$ROOT_DIR/module.prop")"
ZIP_NAME="vbpatch-ksu-webui-${VERSION}.zip"

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$ZIP_NAME"

cd "$ROOT_DIR"
zip -r "$DIST_DIR/$ZIP_NAME" \
  module.prop \
  customize.sh \
  service.sh \
  skip_mount \
  scripts \
  webroot \
  README.md >/dev/null

printf 'Created %s\n' "$DIST_DIR/$ZIP_NAME"
