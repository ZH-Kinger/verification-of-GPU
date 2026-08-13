#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""让 docx 中的表格尽量不跨页。
CSS 的 page-break-inside: avoid 转到 docx 后不生效 —— Word 的表格默认可拆，
须逐行给段落加 w:keepNext（末行除外），并把表前的表题段落一并 keepNext，
使表题、表头与表体连在一起。表格本身超过一页时仍会拆分，此为渲染器行为。
用法: keep_tables.py <文件.docx>
"""
import sys, re, zipfile, shutil

def add_keep(p):
    """给单个 <w:p> 加 keepNext。"""
    if '<w:keepNext/>' in p:
        return p
    m = re.match(r'(<w:p\b[^>]*>)(<w:pPr>)?', p)
    if not m:
        return p
    if m.group(2):
        return p[:m.end()] + '<w:keepNext/>' + p[m.end():]
    return p[:m.end(1)] + '<w:pPr><w:keepNext/></w:pPr>' + p[m.end(1):]

def process_paras(xml):
    out, pos = [], 0
    for m in re.finditer(r'<w:p\b[^>]*>.*?</w:p>|<w:p\b[^>]*/>', xml, re.S):
        out.append(xml[pos:m.start()]); out.append(add_keep(m.group(0))); pos = m.end()
    out.append(xml[pos:])
    return ''.join(out)

src = sys.argv[1]
zin = zipfile.ZipFile(src)
tmp = src + '.tmp'
zout = zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED)
# 行数超过此值的表格本身就超过一页，必须拆分。对其施加 keepNext 只会把
# 整张表推到下一页，反而在前一页留下大片空白。
MAX_ROWS = 18
ntbl = nskip = 0
for it in zin.infolist():
    data = zin.read(it.filename)
    if it.filename == 'word/document.xml':
        x = data.decode('utf-8')
        res, pos = [], 0
        for m in re.finditer(r'<w:tbl>.*?</w:tbl>', x, re.S):
            ntbl += 1
            before = x[pos:m.start()]
            # 表前最后一个段落即表题，一并 keepNext
            pm = list(re.finditer(r'<w:p\b[^>]*>.*?</w:p>', before, re.S))
            if pm:
                last = pm[-1]
                before = before[:last.start()] + add_keep(last.group(0)) + before[last.end():]
            res.append(before)

            tbl = m.group(0)
            rows = re.findall(r'<w:tr\b.*?</w:tr>', tbl, re.S)
            if 1 < len(rows) <= MAX_ROWS:
                for r in rows[:-1]:
                    tbl = tbl.replace(r, process_paras(r), 1)
            elif len(rows) > MAX_ROWS:
                nskip += 1
                # 长表仍让表头随表体：仅首行 keepNext
                tbl = tbl.replace(rows[0], process_paras(rows[0]), 1)
            res.append(tbl); pos = m.end()
        res.append(x[pos:])
        data = ''.join(res).encode('utf-8')
    zout.writestr(it, data)
zout.close(); zin.close()
shutil.move(tmp, src)
print(f'已处理 {ntbl} 张表，其中 {nskip} 张超过 {MAX_ROWS} 行按可拆分处理')
