from pathlib import Path
import json
root=Path(__file__).resolve().parents[2]
out=root/'output/gunsmoke-regression'
rows=[]
for p in sorted(out.rglob('playback.jsonl')):
 samples=[]
 for line in p.read_text().splitlines():
  try: samples.append(json.loads(line))
  except json.JSONDecodeError: pass
 playing=[s for s in samples if s['phase']=='Playing' and s['rate']>0 and not s['muted'] and s['volume']>0]
 advance=max((s['seconds'] for s in playing),default=0)-min((s['seconds'] for s in playing),default=0)
 selected=[s for s in samples if s['file']]
 last=selected[-1] if selected else samples[-1] if samples else {}
 rows.append({'run':str(p.parent.relative_to(out)),'playingSamples':len(playing),'advance':round(advance,3),'bytes':max((s['bytes'] for s in samples),default=0),'file':last.get('file',''),'identifier':last.get('identifier',''),'phase':last.get('phase',''),'error':last.get('error',''),'route':last.get('route',[])})
(out/'transport-summary.json').write_text(json.dumps(rows,indent=2))
print(json.dumps({'runs':len(rows),'sustainedPlayback':sum(r['advance']>=10 for r in rows),'latest':rows[-4:]},indent=2))
