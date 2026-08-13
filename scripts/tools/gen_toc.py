#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 Markdown 中生成或更新「目　录」小节。用法: gen_toc.py <文件.md>"""
import sys, re
p = sys.argv[1]
lines = open(p, encoding='utf-8').read().split('\n')

# 先剔除已有的目录小节
out, i = [], 0
while i < len(lines):
    if lines[i].startswith('## 目　录'):
        i += 1
        while i < len(lines) and not re.match(r'^---+\s*$', lines[i]):
            i += 1
        i += 1
        while i < len(lines) and not lines[i].strip():
            i += 1
        continue
    out.append(lines[i]); i += 1
lines = out

entries = []
for L in lines:
    m = re.match(r'^(#{2,3})\s+(.*)$', L)
    if m and not m.group(2).startswith('目　录'):
        entries.append((len(m.group(1)), m.group(2).strip()))

toc = ['## 目　录', '']
for lv, t in entries:
    toc.append(('' if lv == 2 else '　　') + '- ' + t)
toc += ['', '@@TOC@@', '', '---', '']

# 插到封面表格之后的第一个分隔线后
k = next((j for j, L in enumerate(lines) if re.match(r'^---+\s*$', L)), 0)
res = lines[:k+1] + [''] + toc + lines[k+1:]
open(p, 'w', encoding='utf-8').write('\n'.join(res))
print(f'目录已生成，{len(entries)} 条')
