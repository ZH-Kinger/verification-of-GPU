#!/usr/bin/env bash
# Markdown 转 docx。两遍生成：先出 PDF 取实际分页，再把页码填入目录。
# 用法: bash scripts/tools/md2docx.sh <输入.md> [输出目录]
set -euo pipefail
SRC="${1:?用法: md2docx.sh <输入.md> [输出目录]}"
OUTDIR="${2:-$(dirname "$SRC")}"
BASE="$(basename "${SRC%.md}")"
D="$(dirname "$0")"
TMP="$(mktemp -d)"
mkdir -p "$OUTDIR"
CONV=(soffice --headless -env:UserInstallation="file://$TMP/loprofile" --infilter="HTML (StarWriter)")

python3 "$D/md2html.py" "$SRC" "$TMP/$BASE.html"

# 第一遍：出 PDF 以取得各标题的实际页码
"${CONV[@]}" --convert-to pdf --outdir "$TMP" "$TMP/$BASE.html" >/dev/null 2>&1
python3 "$D/fill_toc_pages.py" "$TMP/$BASE.html" "$TMP/$BASE.pdf"

# 第二遍：带页码的目录转 docx，加页脚后再由 docx 出 PDF，
# 使 PDF 与 docx 版式一致且同样带页码
"${CONV[@]}" --convert-to "docx:MS Word 2007 XML" --outdir "$TMP" "$TMP/$BASE.html" >/dev/null 2>&1
python3 "$D/add_footer.py" "$TMP/$BASE.docx"
rm -f "$TMP/$BASE.pdf"
soffice --headless -env:UserInstallation="file://$TMP/loprofile2" \
        --convert-to pdf --outdir "$TMP" "$TMP/$BASE.docx" >/dev/null 2>&1
mv "$TMP/$BASE.docx" "$OUTDIR/$BASE.docx"
mv "$TMP/$BASE.pdf"  "$OUTDIR/$BASE.pdf"
rm -rf "$TMP"
ls -lh "$OUTDIR/$BASE.docx" "$OUTDIR/$BASE.pdf"
