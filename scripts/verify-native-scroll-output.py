#!/usr/bin/env python3
"""Independent PNG row-order oracle; no production matcher or CG crop/draw."""
import json,pathlib,sys,math
from PIL import Image
import numpy as np
report=pathlib.Path(sys.argv[1]).resolve()
start=json.loads((report/'case-at-start.json').read_text())
data=json.loads((report/'deskcapture-quality-diagnostic.json').read_text())
case=start['case']['id']; row=data['cases'][0]; artifacts=report/'artifacts'
result_path=report/'verified-png-rows.json'
def verify():
 if data.get('scope')!='native-debug-only' or not data.get('success') or row.get('fixtureCase')!=case:raise ValueError('Successful owned native case required')
 frames=row['frames']; axis_positions=[]; widths=[]
 # Measurement condition frozen by the runner before capture. Older reports
 # retain their original vertical-only border policy (zero horizontal inset).
 border=start.get('captureBoundaryInsetPoints',0)
 if type(border) is not int or border not in (0,1):raise ValueError('Unknown native capture boundary policy')
 for number in range(1,frames+1):
  geometry=json.loads((artifacts/f'native-geometry-{number}.json').read_text()); elements=geometry['elements']
  if case.startswith('P'):
   pages=sorted([e for e in elements if e['role']=='AXPage'],key=lambda e:e['matchesOwnedPage'])
   if len(pages)!=6 or [e['matchesOwnedPage'] for e in pages]!=list(range(6)):raise ValueError('Independent page mapping missing')
   axis_positions.append(pages[0]['bounds'][1]); parent=pages[0]['parent']
   while parent>=0 and elements[parent]['role']!='AXScrollArea':parent=elements[parent]['parent']
   if parent<0:raise ValueError('PDF scroll area missing')
   area=elements[parent]['bounds']; paper=pages[0]['bounds']
   left=math.ceil(max(area[0],paper[0]));right=min(area[0]+area[2],paper[0]+paper[2])
   for e in elements:
    if e.get('parent')==parent and e['role']=='AXScrollBar':
     b=e['bounds']
     if b[3]>b[2]:right=min(right,b[0])
   widths.append(math.floor(right)-left-2*border)
  else:
   text=next(e for e in elements if e.get('textMatchesOwnedInput'))
   axis_positions.append(text['anchors'][0]['bounds'][1])
   area=next(e['bounds'] for e in elements if e['role']=='AXScrollArea');right=area[0]+area[2]
   for e in elements:
    if e['role']=='AXScrollBar' and e['bounds'][3]>e['bounds'][2]:right=min(right,e['bounds'][0])
   widths.append(math.floor(right)-math.ceil(area[0])-2*border)
 images=[Image.open(report/'normalized-sources'/f'native-source-{i}.png').convert('RGBA') for i in range(1,frames+1)]
 width,height=images[0].size;scale=width/widths[0]
 if scale not in (1,2) or any(w!=widths[0] for w in widths):raise ValueError('Independent backing-scale evidence inconsistent')
 reverse=start['case']['direction']=='reverse'
 positions=[round((p-axis_positions[0])*scale) for p in axis_positions]
 steps=[(b-a if reverse else a-b) for a,b in zip(positions,positions[1:])]
 if not all(0<step<height for step in steps) or any(i.size!=(width,height) for i in images):raise ValueError('Non-overlapping or changed source frames')
 expected=Image.new('RGBA',(width,height+sum(steps)))
 if reverse:
  cursor=sum(steps);expected.paste(images[0],(0,cursor))
  for image,step in zip(images[1:],steps):cursor-=step;expected.paste(image.crop((0,0,width,step)),(0,cursor))
 else:
  cursor=0;expected.paste(images[0],(0,0));cursor=height
  for image,step in zip(images[1:],steps):expected.paste(image.crop((0,height-step,width,height)),(0,cursor));cursor+=step
 actual=Image.open(artifacts/f'native-{case}.png').convert('RGBA')
 if actual.size!=expected.size:raise ValueError('Output dimensions disagree with AX-derived PNG rows')
 a=np.asarray(actual);b=np.asarray(expected);different=int(np.count_nonzero(np.any(a!=b,axis=2)))
 maximum=int(np.max(np.abs(a.astype(np.int16)-b.astype(np.int16))))
 expected.save(report/'independent-png-row-oracle.png')
 return {'success':different==0,'fixtureCase':case,'oracle':'PNG decoded top-down rows and independent AX coordinates','scale':scale,'captureBoundaryInsetPoints':border,'independentOffsets':positions,'frames':frames,'fullResolutionRGBA':True,'pixelsCompared':actual.width*actual.height,'differingPixels':different,'maximumChannelError':maximum,'sourceColorNormalization':'ColorSync sRGB, original dimensions','productionMatcherUsed':False,'CoreGraphicsCropUsed':False}
try:result=verify()
except Exception as error:result={'success':False,'fixtureCase':case,'error':str(error)}
result_path.write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False));raise SystemExit(0 if result['success'] else 1)
