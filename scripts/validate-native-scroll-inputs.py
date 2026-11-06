#!/usr/bin/env python3
import concurrent.futures,hashlib,json,pathlib,re,subprocess,sys
import pdfplumber
from PIL import Image

root=pathlib.Path(sys.argv[1]).resolve();out=pathlib.Path('tmp/pdfs/r10-input-check').resolve();out.mkdir(parents=True,exist_ok=True)
entries=json.loads((root/'native-inputs.json').read_text())['entries']
poppler='/Users/yanjun/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/override/pdftoppm'
def check(entry):
    file=pathlib.Path(entry['file']);prefix=out/entry['id']
    subprocess.run([poppler,'-r','72','-png',str(file),str(prefix)],check=True,capture_output=True)
    with pdfplumber.open(file) as document:
        assert len(document.pages)==6
        text='\n'.join(page.extract_text() or '' for page in document.pages)
        markers=re.findall(r'ROW(\d{4})',text)
        expected=[f'{i:04}' for i in range(1,6*entry['rowsPerPage']+1)]
        assert markers==expected,(entry['id'],len(markers),len(expected))
        for page in document.pages:
            assert all(-1<=c['x0'] and c['x1']<=641 and -1<=c['top'] and c['bottom']<=901 for c in page.chars),entry['id']
    return {'id':entry['id'],'pages':6,'rows':len(markers),'markersCompleteAndOrdered':True,'textBoundsInsidePage':True,'renderedPages':6}
pdfs=[e for e in entries if e['id'].startswith('P')]
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:results=list(pool.map(check,pdfs))
for group in range(5):
    for page_number in [1,6]:
        sheet=Image.new('RGB',(1280,1800),'#dddddd')
        for i,entry in enumerate(pdfs[group*4:group*4+4]):
            image=Image.open(out/(entry['id']+f'-{page_number}.png')).convert('RGB');sheet.paste(image,(i%2*640,i//2*900))
        sheet.save(out/f'contact-{group}-page-{page_number}.png')
hashes={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob('*')) if p.is_file() and p.name not in ['pdf-input-validation.json','input-hashes.json']}
(root/'input-hashes.json').write_text(json.dumps(hashes,indent=2))
(root/'pdf-input-validation.json').write_text(json.dumps({'inputs':results,'totalPagesRendered':120,'success':True},indent=2))
print('20 PDFs / 120 pages rendered; every row marker ordered and text inside page bounds; input hashes saved.')
