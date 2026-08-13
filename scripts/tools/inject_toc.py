#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 docx 中的 @@TOC@@ 占位段替换为 Word 的自动目录域，并设为打开时更新。
用法: inject_toc.py <文件.docx>
"""
import sys, re, zipfile, shutil, os

FIELD = ('<w:p><w:r><w:fldChar w:fldCharType="begin" w:dirty="true"/></w:r>'
         '<w:r><w:instrText xml:space="preserve"> TOC \\o "1-3" \\h \\z \\u </w:instrText></w:r>'
         '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
         '<w:r><w:t>如未自动生成，请右键此处选择「更新域」</w:t></w:r>'
         '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>')

src = sys.argv[1]
tmp = src + '.tmp'
zin = zipfile.ZipFile(src)
zout = zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED)
done = False
for it in zin.infolist():
    data = zin.read(it.filename)
    if it.filename == 'word/document.xml':
        x = data.decode('utf-8')
        # 占位文字可能被拆进多个 run，故按整段匹配
        new, n = re.subn(r'<w:p\b[^>]*>(?:(?!</w:p>).)*?@@TOC@@(?:(?!</w:p>).)*?</w:p>',
                         lambda _m: FIELD, x, count=1, flags=re.S)
        if n:
            done = True; x = new
        data = x.encode('utf-8')
    elif it.filename == 'word/settings.xml':
        x = data.decode('utf-8')
        if 'updateFields' not in x:
            x = x.replace('</w:settings>', '<w:updateFields w:val="true"/></w:settings>')
        data = x.encode('utf-8')
    zout.writestr(it, data)
zout.close(); zin.close()
if done:
    shutil.move(tmp, src); print('目录域已注入，Word 打开时会提示更新')
else:
    os.remove(tmp); print('未找到 @@TOC@@ 占位，跳过', file=sys.stderr)
