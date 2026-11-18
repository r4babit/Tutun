import json, re, sys, pathlib
ORDER = ['en', 'uk', 'es', 'zh', 'hi', 'ar', 'fr', 'bn', 'pt', 'ur', 'id', 'de', 'ja', 'mr', 'te', 'tr', 'ta', 'vi', 'ko']
PH = re.compile(r'%(?:\d\$)?@')
LOC_KEY = 'Tutun узнаёт имя Wi-Fi, чтобы выключать VPN в доверенных сетях.'
keys = json.load(open('keys.json'))
base = [l.split('\t') for l in open('tr.tsv', encoding='utf-8').read().split('\n') if l.strip()]
rows = {r[0]: {'en': r[1], 'uk': r[2]} for r in base}
bad = []
for code in ORDER[2:]:
    lines = [l for l in open(f'tr_{code}.tsv', encoding='utf-8').read().split('\n') if l.strip()]
    if len(lines) != len(base): bad.append((code, 'lines', len(lines)))
    for l in lines:
        parts = l.split('\t')
        if len(parts) != 2: bad.append((code, 'cols', l[:60])); continue
        ru, t = parts
        if ru not in rows: bad.append((code, 'unknown key', ru[:60])); continue
        rows[ru][code] = t
for ru, tr in rows.items():
    for code in ORDER:
        t = tr.get(code)
        if t is None: bad.append((code, 'missing', ru[:60])); continue
        lead = ru[:len(ru) - len(ru.lstrip(' '))]; trail = ru[len(ru.rstrip(' ')):]
        t = lead + t.strip(' ') + trail; tr[code] = t
        if len(PH.findall(t)) != ru.count('%@') or t.count('%.1f') != ru.count('%.1f'): bad.append((code, 'placeholders', ru[:50], t[:50]))
        if re.search('[‎‏‪-‮⁦-⁩]', t): tr[code] = re.sub('[‎‏‪-‮⁦-⁩]', '', t)
missing_keys = [k for k in keys if k not in rows]
if missing_keys: bad.append(('keys missing', missing_keys))
if bad:
    for b in bad[:40]: print(b)
    sys.exit(1)
esc = lambda s: s.replace('\\', '\\\\').replace('"', '\\"')
out = ['// Создаётся из таблицы переводов. Ключ — русская строка из кода,',
       '// значения — в порядке AppLanguage.translated: ' + ', '.join(ORDER) + '.',
       '// Новая строка в интерфейсе без перевода показывается по-русски.',
       'enum L10nStrings {', '    static let table: [String: [String]] = [']
for ru, tr in rows.items():
    out.append(f'        "{esc(ru)}": [' + ', '.join(f'"{esc(tr[c])}"' for c in ORDER) + '],')
out += ['    ]', '}', '']
root = pathlib.Path(sys.argv[1])
(root / 'Sources/TutunShared/L10nStrings.swift').write_text('\n'.join(out))
for code in ['ru'] + ORDER:
    t = LOC_KEY if code == 'ru' else rows[LOC_KEY][code]
    d = root / 'assets/l10n' / (('zh-Hans' if code == 'zh' else code) + '.lproj'); d.mkdir(parents=True, exist_ok=True)
    (d / 'InfoPlist.strings').write_text(f'"NSLocationUsageDescription" = "{esc(t)}";\n"NSLocationWhenInUseUsageDescription" = "{esc(t)}";\n')
print(len(rows), 'rows ok')
