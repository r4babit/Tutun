#!/usr/bin/env python3
"""Generate Android assets from the same canonical TSV files used by macOS."""
from pathlib import Path
import csv,json,re
root=Path(__file__).resolve().parents[2]
base=root/'scripts/l10n'
langs=['en','uk','es','zh','hi','ar','fr','bn','pt','ur','id','de','ja','mr','te','tr','ta','vi','ko']
table={}
for row in csv.reader((base/'tr.tsv').open(),delimiter='\t'):
    if len(row)>=3:table[row[0]]={'en':row[1],'uk':row[2]}
for code in langs[2:]:
    for row in csv.reader((base/f'tr_{code}.tsv').open(),delimiter='\t'):
        if len(row)>=2 and row[0] in table:table[row[0]][code]=row[1]
supplement=json.loads((base/'android-extra.json').read_text())
for key,values in supplement['strings'].items():table[key]=values
for key,target in supplement['aliases'].items():
    if target not in table:raise SystemExit('Missing shared alias: '+target)
    table[key]=table[target].copy()
source=root/'platforms/android/app/src/main/java/app/tutun'
keys=sorted({json.loads('"'+key+'"') for f in source.glob('*.kt') for key in re.findall(r'\btr\("((?:\\.|[^"\\])*)"',f.read_text())})
(base/'android-keys.json').write_text(json.dumps(keys,ensure_ascii=False,indent=2)+'\n')
for key in keys:
    if key not in table:raise SystemExit('Untranslated Android key: '+key)
    for code in langs:
        if not table[key].get(code):raise SystemExit('Missing Android translation: '+key+' '+code)
    for code,value in table[key].items():
        if key.count('%@')!=len(re.findall(r'%(?:[1-9]\$)?@',value)):raise SystemExit('Placeholder mismatch: '+key+' '+code)
asset=root/'platforms/android/app/src/main/assets/l10n.json'
asset.write_text(json.dumps(table,ensure_ascii=False,separators=(',',':'))+'\n')
print(f'Android catalog: {len(table)} keys, {len(langs)+1} languages; {sum(len(table[k])<19 for k in keys)} Android-specific keys use English fallback outside ru/uk/en.')
