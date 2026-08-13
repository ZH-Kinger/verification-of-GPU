#!/usr/bin/env bash
# Markdown 转 docx 与 PDF。
#
# 目录页码需迭代求解：填入页码会改变目录长度，进而改变正文分页。
# 且必须在最终渲染路径（HTML 转 docx 再转 PDF）上迭代 —— HTML 直转 PDF
# 与经 docx 中转的分页并不一致，在前者上收敛的页码用到后者上仍是错的。
#
# 用法: bash scripts/tools/md2docx.sh <输入.md> [输出目录]
set -euo pipefail
SRC="${1:?用法: md2docx.sh <输入.md> [输出目录]}"
OUTDIR="${2:-$(dirname "$SRC")}"
BASE="$(basename "${SRC%.md}")"
D="$(dirname "$0")"
TMP="$(mktemp -d)"
mkdir -p "$OUTDIR"
# 连续多次 headless 转换会因用户配置目录加锁而静默失败，故隔离配置目录
LO=(soffice --headless -env:UserInstallation="file://$TMP/lo")

build() {   # build <是否清除哨兵>
  python3 "$D/md2html.py" "$SRC" "$TMP/$BASE.html" "$TMP/pages.json"
  [ "${1:-no}" = "clean" ] && sed -i 's/@@TOCEND@@//' "$TMP/$BASE.html"
  rm -f "$TMP/$BASE.docx" "$TMP/$BASE.pdf"
  "${LO[@]}" --infilter="HTML (StarWriter)" --convert-to "docx:MS Word 2007 XML" \
             --outdir "$TMP" "$TMP/$BASE.html" >/dev/null 2>&1
  python3 "$D/keep_tables.py" "$TMP/$BASE.docx" >/dev/null
  python3 "$D/add_footer.py" "$TMP/$BASE.docx" >/dev/null
  "${LO[@]}" --convert-to pdf --outdir "$TMP" "$TMP/$BASE.docx" >/dev/null 2>&1
}

echo '{}' > "$TMP/pages.json"; echo '{}' > "$TMP/prev.json"
for it in 1 2 3 4; do
  build
  python3 "$D/toc_pages.py" "$TMP/$BASE.html" "$TMP/$BASE.pdf" "$TMP/pages.json"
  if cmp -s "$TMP/pages.json" "$TMP/prev.json"; then echo "第 $it 轮页码收敛"; break; fi
  cp "$TMP/pages.json" "$TMP/prev.json"
done

# 定稿：清除哨兵文字（<p> 仍在，1pt 高度不变，分页与迭代结果一致）
build clean
mv "$TMP/$BASE.docx" "$OUTDIR/$BASE.docx"
mv "$TMP/$BASE.pdf"  "$OUTDIR/$BASE.pdf"
rm -rf "$TMP"
ls -lh "$OUTDIR/$BASE.docx" "$OUTDIR/$BASE.pdf"
