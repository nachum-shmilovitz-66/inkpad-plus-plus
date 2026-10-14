#!/usr/bin/env python3
"""Generates MacPad/Sources/LanguageMenuTable.swift from Notepad++'s compact Language menu
(the second "&Language" popup in Notepad_plus.rc, with letter submenus). Run from the repo root:
    python3 -I scripts/gen-language-menu.py
User Defined Language entries are left out until UDL support exists."""
import re

rc = open('vendor/notepad-plus-plus/PowerEditor/src/Notepad_plus.rc', encoding='utf-8', errors='replace').read()
table = open('MacPad/Sources/LanguageTable.swift').read()
by_type = dict((t, n) for n, t in re.findall(
    r'name: "([^"]+)", shortName: "[^"]*", longName: "[^"]*", langType: "(\w+)"', table))
special = {'IDM_LANG_JS': 'L_JAVASCRIPT'}


def language(idm):
    name = by_type.get(special.get(idm, 'L_' + idm[len('IDM_LANG_'):]))
    return None if name == 'udf' else name


starts = [m.start() for m in re.finditer(r'POPUP "&Language"', rc)]
lines = rc[starts[1]:].splitlines()[1:]
entries, depth, current = [], 0, None
for line in lines:
    t = line.strip()
    if t == 'BEGIN':
        depth += 1
        continue
    if t == 'END':
        depth -= 1
        if depth == 0:
            break
        if current is not None and current[1]:
            entries.append(('sub', current[0], current[1]))
        current = None
        continue
    m = re.match(r'POPUP "([^"]+)"', t)
    if m:
        current = (m.group(1), [])
        continue
    if t.startswith('MENUITEM SEPARATOR'):
        if current is None:
            entries.append(('sep',))
        continue
    m = re.match(r'MENUITEM "([^"]+)",\s*(\w+)', t)
    if m and language(m.group(2)):
        item = (m.group(1), language(m.group(2)))
        (current[1] if current is not None else entries).append(item if current is not None else ('item',) + item)
while entries and entries[-1][0] == 'sep':
    entries.pop()


def q(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


out = ['// Generated from Notepad++ v8.9.8.1 Notepad_plus.rc (the compact "&Language" menu, letter',
       '// submenus) by scripts/gen-language-menu.py. Values are langs.model.xml names.',
       '// Do not edit by hand; regenerate instead. User Defined Language entries are left out.', '',
       'enum LanguageMenuEntry {', '    case item(title: String, language: String)', '    case separator',
       '    case submenu(title: String, items: [(title: String, language: String)])', '}', '',
       'let languageMenuEntries: [LanguageMenuEntry] = [']
for e in entries:
    if e[0] == 'sep':
        out.append('    .separator,')
    elif e[0] == 'item':
        out.append(f'    .item(title: {q(e[1])}, language: {q(e[2])}),')
    else:
        out.append(f'    .submenu(title: {q(e[1])}, items: [' + ', '.join(f'({q(a)}, {q(b)})' for a, b in e[2]) + ']),')
out.append(']')
open('MacPad/Sources/LanguageMenuTable.swift', 'w').write('\n'.join(out) + '\n')
