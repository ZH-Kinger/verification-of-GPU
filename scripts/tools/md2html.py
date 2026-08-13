#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Markdown 子集转 Word 友好的 HTML，供 LibreOffice 转 docx 用。
支持：标题、段落、表格、有序与无序列表、围栏代码块、行内代码、加粗、分隔线。
"""
import sys, os, re, html

CSS = """
@page { size: A4; margin: 2.2cm 1.9cm; }
body { font-family: "SimSun","宋体",serif; font-size: 10.5pt; line-height: 1.45; }
h1 { font-family:"SimHei","黑体",sans-serif; font-size:18pt; text-align:center; margin:0 0 10pt; }
table.meta { width: 70%; margin: 40pt auto 0; font-size: 11pt;
             page-break-after: always; }
table.meta td { border: none; padding: 1pt 4pt; }
table.meta td:first-child { font-family:"SimHei","黑体",sans-serif; width: 34%; }
h2 { font-family:"SimHei","黑体",sans-serif; font-size:14pt; margin:16pt 0 6pt;
     page-break-after: avoid; }
h3 { font-family:"SimHei","黑体",sans-serif; font-size:12pt; margin:12pt 0 4pt; page-break-after: avoid; }
h4 { font-family:"SimHei","黑体",sans-serif; font-size:11pt; margin:9pt 0 3pt; page-break-after: avoid; }
p  { margin: 0 0 4pt; text-align: justify; }
p.tocend { font-size: 1pt; color: #fff; margin: 0; }
h2.pb { page-break-before: always; margin-top: 0; }
p.cap { font-family:"SimHei","黑体",sans-serif; font-size:10.5pt; margin:10pt 0 3pt; }
caption { font-family:"SimHei","黑体",sans-serif; font-size:10pt; text-align:left;
          padding: 8pt 0 3pt; caption-side: top; }
/* 表格整体不拆页：表头留在上一页而正文另起一页是最常见的排版事故。
   超过一页的长表由渲染器自行拆分，此设置对其无效。 */
table { border-collapse: collapse; width: 100%; font-size: 8.5pt; margin: 0 0 8pt;
        page-break-inside: avoid; }
tr { page-break-inside: avoid; }
table.toc { margin-top: 3pt; }
table.toc td { border: none; font-size: 9pt; padding: 0 2pt; line-height: 1.1; }
table.toc td.t2 { font-family:"SimHei","黑体",sans-serif; width: 36%; }
table.toc td.t3 { padding-left: 12pt; width: 36%; }
table.toc td.pn { text-align: right; width: 6%; padding-right: 8pt; }
th, td { border: 0.5pt solid #000; padding: 2pt 4pt; vertical-align: top; line-height: 1.3; }
th { background: #e8e8e8; font-family:"SimHei","黑体",sans-serif; }
pre { font-family:"Consolas",monospace; font-size:9pt; background:#f5f5f5;
      border:0.5pt solid #bbb; padding:6pt; white-space:pre-wrap; }
code { font-family:"Consolas",monospace; font-size:10pt; }
hr { border:0; border-top:0.5pt solid #999; margin:10pt 0; }
ol, ul { margin: 0 0 4pt 0; padding-left: 20pt; }
li { margin-bottom: 2pt; }
"""

def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', t)
    t = t.replace('\\_', '_')
    return t

def main():
    src, dst = sys.argv[1], sys.argv[2]
    # 可选：目录页码映射。首轮无映射时占位为 88，与两位页码等宽。
    pages_map = {}
    if len(sys.argv) > 3 and os.path.exists(sys.argv[3]):
        import json
        pages_map = json.load(open(sys.argv[3], encoding='utf-8'))
    lines = open(src, encoding='utf-8').read().split('\n')
    out, i, n = [], 0, len(lines)
    toc_items = []
    pending_break = False
    skip_toc = False          # md 中的静态目录仅供 md 阅读，docx 用域生成，此处跳过
    while i < n:
        L = lines[i]
        if skip_toc:
            if L.strip() == '@@TOC@@':
                skip_toc = False
                # 双栏排布。单栏 53 条会占三页且末页仅数行；
                # 段落加点线的方案因无制表位，点数难以对齐，故仍用表格但两条一行。
                half = (len(toc_items) + 1) // 2
                left, right = toc_items[:half], toc_items[half:]
                right += [(0, '')] * (len(left) - len(right))
                rows = []
                for (l1, t1), (l2, t2) in zip(left, right):
                    def cell(lv, t):
                        if not t:
                            return '<td></td><td></td>'
                        return (f'<td class="t{lv}">{inline(t)}</td>'
                                # 占位用两位数，与最终页码等宽，
                                # 使两遍生成的版式一致，页码不会因目录长度变化而偏移
                                f'<td class="pn" title="{html.escape(t)}">'
                                f'{pages_map.get(t, "88")}</td>')
                    rows.append('<tr>' + cell(l1, t1) + cell(l2, t2) + '</tr>')
                out.append('<table class="toc">' + ''.join(rows) + '</table>')
                # 哨兵：标记目录结束位置。去掉章前分页后目录尾与正文首章同页，
                # 按整页排除会漏掉该页上的标题，故改用位置而非页面粒度。
                out.append('<p class="tocend">@@TOCEND@@</p>')
                # 空段落上的 page-break-after 会被 LibreOffice 忽略，
                # 故改由目录之后的首个章标题承担分页
                pending_break = True
            else:
                m2 = re.match(r'^(\s*)-\s+(.*)$', L)
                if m2:
                    toc_items.append((2 if not m2.group(1).strip('　') else 3, m2.group(2).strip()))
            i += 1; continue
        if L.startswith('```'):
            buf = []; i += 1
            while i < n and not lines[i].startswith('```'):
                buf.append(html.escape(lines[i])); i += 1
            i += 1
            out.append('<pre>' + '\n'.join(buf) + '</pre>')
            continue
        if re.match(r'^\s*---+\s*$', L):
            out.append('<hr/>'); i += 1; continue
        m = re.match(r'^(#{1,4})\s+(.*)$', L)
        if m:
            lv = len(m.group(1))
            if pending_break:
                pending_break = False
                out.append(f'<h{lv} class="pb">{inline(m.group(2))}</h{lv}>'); i += 1; continue
            if m.group(2).startswith('目　录'):
                skip_toc = True
                out.append(f'<h{lv}>{inline(m.group(2))}</h{lv}>'); i += 1; continue
            out.append(f'<h{lv}>{inline(m.group(2))}</h{lv}>'); i += 1; continue
        if L.lstrip().startswith('|') and i + 1 < n and re.match(r'^\s*\|[\s:|-]+\|\s*$', lines[i+1]):
            cap = ''
            if out and out[-1].startswith('<p class="cap">'):
                cap = '<caption>' + out.pop()[len('<p class="cap">'):-len('</p>')] + '</caption>'
            def cells(x): return [c.strip() for c in x.strip().strip('|').split('|')]
            hdr = cells(L); i += 2
            rows = []
            while i < n and lines[i].lstrip().startswith('|'):
                rows.append(cells(lines[i])); i += 1
            cls = ' class="meta"' if (not out or all('<table' not in o for o in out)) and hdr == ['', ''] else ''
            t = [f'<table{cls}>' + cap + ('' if cls else '<tr>' + ''.join(f'<th>{inline(c)}</th>' for c in hdr) + '</tr>')]
            for r in rows:
                r = (r + [''] * len(hdr))[:len(hdr)]
                t.append('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>')
            t.append('</table>')
            out.append('\n'.join(t)); continue
        if re.match(r'^\d+\.\s', L.strip()):
            items = []
            while i < n and re.match(r'^\d+\.\s', lines[i].strip()):
                items.append(re.sub(r'^\d+\.\s*', '', lines[i].strip())); i += 1
                while i < n and lines[i].startswith('   ') and lines[i].strip():
                    items[-1] += lines[i].strip(); i += 1
            out.append('<ol>' + ''.join(f'<li>{inline(x)}</li>' for x in items) + '</ol>')
            continue
        if L.strip().startswith('- '):
            items = []
            while i < n and lines[i].strip().startswith('- '):
                items.append(lines[i].strip()[2:]); i += 1
            out.append('<ul>' + ''.join(f'<li>{inline(x)}</li>' for x in items) + '</ul>')
            continue
        if L.strip() == '@@TOC@@':
            out.append('<p>@@TOC@@</p>'); i += 1; continue
        if not L.strip():
            i += 1; continue
        para = [L.strip()]; i += 1
        while i < n and lines[i].strip() and not re.match(r'^(#{1,4}\s|\||```|---+\s*$|\d+\.\s|- )', lines[i].lstrip()):
            para.append(lines[i].strip()); i += 1
        txt = ''.join(para)
        cls = ' class="cap"' if re.match(r'^表\s*[A-Z0-9]+-\d+', txt) else ''
        out.append(f'<p{cls}>{inline(txt)}</p>')

    open(dst, 'w', encoding='utf-8').write(
        f'<html><head><meta charset="utf-8"/><style>{CSS}</style></head><body>\n'
        + '\n'.join(out) + '\n</body></html>')
    print(f'{dst} 已生成')

if __name__ == '__main__':
    main()
