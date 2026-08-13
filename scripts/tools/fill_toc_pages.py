#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 PDF 的实际分页填充 HTML 目录中的 @@P:标题@@ 占位。
用法: fill_toc_pages.py <html> <pdf>
"""
import sys, re, subprocess

html_path, pdf = sys.argv[1], sys.argv[2]
s = open(html_path, encoding='utf-8').read()
titles = re.findall(r'@@P:(.*?)@@', s)
if not titles:
    print('无占位，跳过'); sys.exit()

npages = int(re.search(r'Pages:\s+(\d+)',
    subprocess.run(['pdfinfo', pdf], capture_output=True).stdout.decode()).group(1))
pages = []
for i in range(1, npages + 1):
    t = subprocess.run(['pdftotext', '-f', str(i), '-l', str(i), pdf, '-'],
                       capture_output=True).stdout.decode('utf-8', 'replace')
    pages.append(re.sub(r'\s+', '', t))

# 目录页的识别：第一遍 PDF 中目录条目仍是 @@P:标题@@ 占位，
# 该串只出现在目录页，是最可靠的标记。按标题命中数或字符占比判断都会误判：
# 正文首页小节多时同样能命中多条，而占位文字又会稀释字符占比。
toc_pages = {i for i, txt in enumerate(pages) if '@@P:' in txt}
if toc_pages:
    print(f'目录占第 {min(toc_pages)+1} 至 {max(toc_pages)+1} 页')
else:
    print('警告：未在 PDF 中找到目录占位，页码可能填成目录页自身')

found = 0
for t in titles:
    key = re.sub(r'\s+', '', t)
    pg = next((i + 1 for i, txt in enumerate(pages) if i not in toc_pages and key in txt), None)
    if pg:
        found += 1
    else:
        print(f'  未定位: {t}')
    s = s.replace(f'@@P:{t}@@', str(pg) if pg else '')
open(html_path, 'w', encoding='utf-8').write(s)
print(f'目录页码已填充 {found}/{len(titles)} 条，正文共 {npages} 页')
