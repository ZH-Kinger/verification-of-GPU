#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 PDF 提取各目录条目的实际页码，写成 JSON 映射。
用法: toc_pages.py <html> <pdf> <out.json>
"""
import sys, re, json, subprocess

html_path, pdf, out = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(html_path, encoding='utf-8').read()
titles = re.findall(r'<td class="pn" title="(.*?)">', s)
if not titles:
    json.dump({}, open(out, 'w')); print('无目录条目'); sys.exit()

n = int(re.search(r'Pages:\s+(\d+)',
    subprocess.run(['pdfinfo', pdf], capture_output=True).stdout.decode()).group(1))
joined, bounds = '', []
for i in range(1, n + 1):
    t = subprocess.run(['pdftotext', '-f', str(i), '-l', str(i), pdf, '-'],
                       capture_output=True).stdout.decode('utf-8', 'replace')
    bounds.append((len(joined), i))
    joined += re.sub(r'\s+', '', t)

# 目录本身含全部标题文字，须自哨兵之后开始检索
cut = joined.find('@@TOCEND@@')
if cut < 0:
    cut = 0
    print('警告：未找到目录结束哨兵，页码可能填成目录页自身')

def page_of(pos):
    pg = 1
    for start, p in bounds:
        if start <= pos:
            pg = p
    return pg

m, miss = {}, []
for t in titles:
    key = re.sub(r'\s+', '', t)
    pos = joined.find(key, cut)
    if pos >= 0:
        m[t] = page_of(pos)
    else:
        miss.append(t)
json.dump(m, open(out, 'w', encoding='utf-8'), ensure_ascii=False)
print(f'定位 {len(m)}/{len(titles)} 条，PDF 共 {n} 页' + (f'，未定位: {miss}' if miss else ''))
