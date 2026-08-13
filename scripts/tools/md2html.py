#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Markdown 子集转 Word 友好的 HTML，供 LibreOffice 转 docx 用。
支持：标题、段落、表格、有序与无序列表、围栏代码块、行内代码、加粗、分隔线。
"""
import sys, re, html

CSS = """
@page { size: A4; margin: 2.5cm 2cm; }
body { font-family: "SimSun","宋体",serif; font-size: 11pt; line-height: 1.7; }
h1 { font-family:"SimHei","黑体",sans-serif; font-size:20pt; text-align:center; margin:0 0 6pt; }
h2 { font-family:"SimHei","黑体",sans-serif; font-size:15pt; margin:22pt 0 8pt;
     page-break-before: always; page-break-after: avoid; }
h3 { font-family:"SimHei","黑体",sans-serif; font-size:13pt; margin:16pt 0 6pt; page-break-after: avoid; }
h4 { font-family:"SimHei","黑体",sans-serif; font-size:11.5pt; margin:12pt 0 4pt; page-break-after: avoid; }
p  { margin: 0 0 6pt; text-align: justify; }
p.cap { font-family:"SimHei","黑体",sans-serif; font-size:10.5pt; margin:10pt 0 3pt; page-break-after: avoid; }
table { border-collapse: collapse; width: 100%; font-size: 9.5pt; margin: 0 0 10pt;
        page-break-inside: auto; }
tr { page-break-inside: avoid; }
table.toc { margin-top: 4pt; }
table.toc td { border: none; font-size: 9.5pt; padding: 1pt 2pt; }
table.toc td.t2 { font-family:"SimHei","黑体",sans-serif; width: 36%; }
table.toc td.t3 { padding-left: 12pt; width: 36%; }
table.toc td.pn { text-align: right; width: 6%; padding-right: 8pt; }
th, td { border: 0.5pt solid #000; padding: 3pt 5pt; vertical-align: top; }
th { background: #e8e8e8; font-family:"SimHei","黑体",sans-serif; }
pre { font-family:"Consolas",monospace; font-size:9.5pt; background:#f5f5f5;
      border:0.5pt solid #bbb; padding:6pt; white-space:pre-wrap; }
code { font-family:"Consolas",monospace; font-size:10pt; }
hr { border:0; border-top:0.5pt solid #999; margin:10pt 0; }
ol, ul { margin: 0 0 6pt 0; padding-left: 22pt; }
li { margin-bottom: 3pt; }
"""

def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', t)
    t = t.replace('\\_', '_')
    return t

def main():
    src, dst = sys.argv[1], sys.argv[2]
    lines = open(src, encoding='utf-8').read().split('\n')
    out, i, n = [], 0, len(lines)
    toc_items = []
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
                                f'<td class="pn">@@P:{t}@@</td>')
                    rows.append('<tr>' + cell(l1, t1) + cell(l2, t2) + '</tr>')
                out.append('<table class="toc">' + ''.join(rows) + '</table>')
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
            if m.group(2).startswith('目　录'):
                skip_toc = True
                out.append(f'<h{lv}>{inline(m.group(2))}</h{lv}>'); i += 1; continue
            out.append(f'<h{lv}>{inline(m.group(2))}</h{lv}>'); i += 1; continue
        if L.lstrip().startswith('|') and i + 1 < n and re.match(r'^\s*\|[\s:|-]+\|\s*$', lines[i+1]):
            def cells(x): return [c.strip() for c in x.strip().strip('|').split('|')]
            hdr = cells(L); i += 2
            rows = []
            while i < n and lines[i].lstrip().startswith('|'):
                rows.append(cells(lines[i])); i += 1
            t = ['<table><tr>' + ''.join(f'<th>{inline(c)}</th>' for c in hdr) + '</tr>']
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
