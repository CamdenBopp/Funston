from pathlib import Path
import subprocess, os, json, shutil, tarfile, io, time, re, argparse, fcntl
REPO=Path(__file__).resolve().parents[2]
OUT=REPO/'output/gunsmoke-regression'
CHECK=Path('/tmp/funston-gunsmoke-history')
SIM='363DF0A7-33E9-42BB-91C2-5EE62E11F6C2'
CACHE='/Users/camden/Library/Developer/Xcode/DerivedData/Funston-gyrwrasragklwoehlphlcwrdazib/SourcePackages'
ENV=dict(os.environ,PATH='/usr/bin:/bin:/usr/sbin:/sbin')
parser=argparse.ArgumentParser()
parser.add_argument('--refs', nargs='+', help='Specific commit refs to verify instead of all history')
parser.add_argument('--output', help='Separate output directory for repeat runs')
args=parser.parse_args()
if args.output: OUT=Path(args.output).resolve(); OUT.mkdir(parents=True,exist_ok=True)
lock=open('/tmp/funston-gunsmoke-regression.lock','w')
try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError: parser.error('Another audit is using the dedicated simulator and checkout')
commits=[subprocess.check_output(['git','rev-parse',ref],cwd=REPO,text=True).strip() for ref in args.refs] if args.refs else subprocess.check_output(['git','rev-list','HEAD'],cwd=REPO,text=True).splitlines()
manifest=OUT/'results.jsonl'
completed={json.loads(l)['commit'] for l in manifest.read_text().splitlines()} if manifest.exists() else set()
for n, commit in enumerate(commits,1):
 if commit in completed: continue
 short=commit[:7]; folder=OUT/short
 if folder.exists(): folder.rename(OUT/(short+'.interrupted-'+str(int(time.time()))))
 folder.mkdir()
 print(f'[{n}/{len(commits)}] {short} starting',flush=True)
 STAGING=Path('/tmp/funston-gunsmoke-staging')
 if STAGING.exists(): shutil.rmtree(STAGING)
 STAGING.mkdir()
 CHECK.mkdir(exist_ok=True)
 data=subprocess.check_output(['git','archive',commit],cwd=REPO)
 with tarfile.open(fileobj=io.BytesIO(data)) as tar: tar.extractall(STAGING,filter='data')
 app=subprocess.check_output(['/usr/bin/python3',str(Path(__file__).with_name('inject.py')),str(STAGING)],text=True).strip()
 subprocess.run(['/usr/bin/rsync','-a','--checksum','--delete',str(STAGING)+'/',str(CHECK)+'/'],check=True)
 bundle='com.camden.'+app
 # Only this dedicated test simulator is cleared. Phone data is never removed.
 subprocess.run(['xcrun','simctl','uninstall',SIM,bundle],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=ENV)
 command=['xcrun','xcodebuild','-project',app+'.xcodeproj','-scheme',app,'-configuration','Debug','-destination','platform=iOS Simulator,id='+SIM,'-derivedDataPath','/tmp/funston-gunsmoke-history-derived','-clonedSourcePackagesDirPath',CACHE,'-disableAutomaticPackageResolution','-collect-test-diagnostics','never','-only-testing:'+app+'UITests/'+app+'UITests/testGunsmokeSustainedPlayback','-resultBundlePath',str(folder/'test.xcresult'),'CODE_SIGNING_ALLOWED=NO','test']
 start=time.time()
 try:
  with (folder/'build.log').open('w') as log:
   result=subprocess.run(command,cwd=CHECK,env=ENV,stdout=log,stderr=subprocess.STDOUT,timeout=900)
  code=result.returncode
 except subprocess.TimeoutExpired: code=124
 container=subprocess.run(['xcrun','simctl','get_app_container',SIM,bundle,'data'],capture_output=True,text=True,env=ENV)
 if container.returncode==0:
  trace=Path(container.stdout.strip())/'Documents/gunsmoke-playback.jsonl'
  if trace.exists(): shutil.copy(trace,folder/'playback.jsonl')
 samples=[]
 if (folder/'playback.jsonl').exists():
  for line in (folder/'playback.jsonl').read_text().splitlines():
   try: samples.append(json.loads(line))
   except json.JSONDecodeError: pass
 playing=[s for s in samples if s['rate']>0 and not s['muted'] and s['volume']>0 and s['itemStatus']==1 and s['identifier'] in ['OTRR_Gunsmoke_Singles','GUNSMOKE01']]
 advance=max([s['seconds'] for s in playing],default=0)-min([s['seconds'] for s in playing],default=0)
 log=(folder/'build.log').read_text(errors='replace')
 record=dict(identifier=playing[0]['identifier'] if playing else '',file=playing[0]['file'] if playing else '',commit=commit,subject=subprocess.check_output(['git','show','-s','--format=%s',commit],cwd=REPO,text=True).strip(),exit=code,uiPassed=code==0,playingSamples=len(playing),advancedSeconds=advance,verifiedTransport=code==0 and advance>=10,seconds=round(time.time()-start),errors=[l[:600] for l in log.splitlines() if 'error:' in l][:8])
 with manifest.open('a') as f: f.write(json.dumps(record)+'\n')
 print(json.dumps(record),flush=True)
