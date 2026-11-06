"""One-time SwiftParser range migration; never edits persisted enum raw values.
Input snapshot was extracted with extract.swift. Human translations live in en.tsv.
"""
import json,re,collections
from pathlib import Path
root=Path(__file__).resolve().parents[2]
entries=[] if '--migrate-source' not in __import__('sys').argv else json.loads((root/'build/localization-source.json').read_text())
keys=json.loads((root/'scripts/localization/source-keys.json').read_text())
translations={}
for row in (root/'scripts/localization/en.tsv').read_text().splitlines():
 if not row:continue
 number,value=row.split('\t',1);translations[keys[int(number)]]=value.replace('\\n','\n')
# Translation resources are regenerated deterministically without touching UI source again.
missing=[k for k in keys if k not in translations]
if missing:raise SystemExit(f'Missing {len(missing)} translations')
for language in ['en','zh-Hans']:
 folder=root/'Sources/DeskCapture/Resources'/f'{language}.lproj';folder.mkdir(exist_ok=True)
 rows=[]
 for key in keys:
  value=translations.get(key,key) if language=='en' else key
  rows.append(json.dumps(key,ensure_ascii=False)+' = '+json.dumps(value,ensure_ascii=False)+';')
 for key, pair in json.loads((root/'scripts/localization/extra-strings.json').read_text()).items():
  if key not in keys: rows.append(json.dumps(key,ensure_ascii=False)+' = '+json.dumps(pair[language],ensure_ascii=False)+';')
 (folder/'Localizable.strings').write_text('\n'.join(rows)+'\n')
if '--migrate-source' not in __import__('sys').argv:raise SystemExit()
byfile=collections.defaultdict(list)
for entry in entries:
 name=Path(entry['file']).name
 if any(x in name for x in ['Diagnostic','Benchmark','Fixture']):continue
 if entry['raw']:continue
 # Native names for language selection and stable exported project paths are not translated.
 if entry['key']=='日本語':continue
 byfile[entry['file']].append(entry)
backup=root/'build/localization-source-snapshot';backup.mkdir(exist_ok=True)
for file,items in byfile.items():
 p=root/file;data=p.read_bytes();(backup/p.name).write_bytes(data)
 changes=[]
 for e in items:
  assert data[e['start']:e['end']].decode()==e['literal'],(file,e['key'])
  changes.extend([(e['end'],b')'),(e['start'],b'L10n.text(')])
 for pos,value in sorted(changes,reverse=True):data=data[:pos]+value+data[pos:]
 p.write_bytes(data)
print('Migrated',sum(map(len,byfile.values())),'UI literals in',len(byfile),'files; translations',len(translations),'of',len(keys))
