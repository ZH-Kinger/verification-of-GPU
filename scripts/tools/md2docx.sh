#!/usr/bin/env bash
# Markdown 转 docx。用法: bash scripts/tools/md2docx.sh <输入.md> [输出目录]
set -euo pipefail
SRC="${1:?用法: md2docx.sh <输入.md> [输出目录]}"
OUTDIR="${2:-$(dirname "$SRC")}"
BASE="$(basename "${SRC%.md}")"
TMP="$(mktemp -d)"
python3 "$(dirname "$0")/md2html.py" "$SRC" "$TMP/$BASE.html"
soffice --headless --infilter="HTML (StarWriter)" --convert-to "docx:MS Word 2007 XML" --outdir "$TMP" "$TMP/$BASE.html" >/dev/null 2>&1
python3 "$(dirname "$0")/inject_toc.py" "$TMP/$BASE.docx" || true
mv "$TMP/$BASE.docx" "$OUTDIR/$BASE.docx"
rm -rf "$TMP"
ls -lh "$OUTDIR/$BASE.docx"
