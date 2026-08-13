#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为 docx 添加居中页码页脚。目录标注了页码，正文若无页码则目录不可用。
用法: add_footer.py <文件.docx>
"""
import sys, re, zipfile, shutil, os

FOOTER = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:p><w:pPr><w:jc w:val="center"/><w:rPr><w:sz w:val="18"/></w:rPr></w:pPr>
<w:r><w:rPr><w:sz w:val="18"/></w:rPr><w:t>— </w:t></w:r>
<w:r><w:fldChar w:fldCharType="begin"/></w:r>
<w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>
<w:r><w:fldChar w:fldCharType="separate"/></w:r>
<w:r><w:rPr><w:sz w:val="18"/></w:rPr><w:t>1</w:t></w:r>
<w:r><w:fldChar w:fldCharType="end"/></w:r>
<w:r><w:rPr><w:sz w:val="18"/></w:rPr><w:t> —</w:t></w:r>
</w:p></w:ftr>'''

src = sys.argv[1]
tmp = src + '.tmp'
zin = zipfile.ZipFile(src)
names = zin.namelist()
if 'word/footer1.xml' in names:
    print('已有页脚，跳过'); sys.exit()

# 取一个未占用的关系 id
rels = zin.read('word/_rels/document.xml.rels').decode('utf-8')
used = {int(x) for x in re.findall(r'Id="rId(\d+)"', rels)}
rid = f'rId{max(used) + 1 if used else 1}'

zout = zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED)
for it in zin.infolist():
    data = zin.read(it.filename)
    if it.filename == 'word/_rels/document.xml.rels':
        x = data.decode('utf-8').replace('</Relationships>',
            f'<Relationship Id="{rid}" Type="http://schemas.openxmlformats.org/'
            f'officeDocument/2006/relationships/footer" Target="footer1.xml"/></Relationships>')
        data = x.encode('utf-8')
    elif it.filename == '[Content_Types].xml':
        x = data.decode('utf-8').replace('</Types>',
            '<Override PartName="/word/footer1.xml" ContentType="application/vnd.'
            'openxmlformats-officedocument.wordprocessingml.footer+xml"/></Types>')
        data = x.encode('utf-8')
    elif it.filename == 'word/document.xml':
        x = data.decode('utf-8')
        # sectPr 内 footerReference 须置于 pgSz 之前，否则 Word 视为无效
        x = re.sub(r'(<w:sectPr\b[^>]*>)',
                   r'\1<w:footerReference w:type="default" r:id="' + rid + '"/>',
                   x, count=1)
        data = x.encode('utf-8')
    zout.writestr(it, data)
zout.writestr('word/footer1.xml', FOOTER)
zout.close(); zin.close()
shutil.move(tmp, src)
print('页脚页码已添加')
