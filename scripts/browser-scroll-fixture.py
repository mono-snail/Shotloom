#!/usr/bin/env python3
"""Loopback-only real-browser fixture. No accounts, remote assets or user data."""
import http.server, json, pathlib, sys, time, urllib.parse, subprocess, threading, uuid, secrets

root = pathlib.Path(sys.argv[1]).resolve()
states = {}; jobs = {}; job_lock = threading.Lock(); control_key = secrets.token_hex(24)
repository = pathlib.Path(__file__).resolve().parent.parent
HTML = r'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>DC Browser Fixture</title>
<style>body{margin:0;background:#e8edf2;font:14px system-ui}#capture{position:absolute;left:40px;top:50px;width:480px;height:300px;overflow:hidden}#viewport{position:absolute;inset:0;overflow:auto;scrollbar-width:none;overscroll-behavior:none;scroll-behavior:auto}#viewport::-webkit-scrollbar{display:none}#page{display:block;width:480px;height:4500px;image-rendering:pixelated}.bar{position:absolute;left:0;width:480px;pointer-events:none;image-rendering:pixelated}#header{top:0;height:36px}#footer{bottom:0;height:28px}#status{position:absolute;top:8px;left:40px}</style>
<div id="status">本机生成的长图验证样本</div><div id="capture" role="region" tabindex="0"><div id="viewport" tabindex="0"><img id="page" src="vertical.png"></div><img class="bar" id="header" src="header.png"><img class="bar" id="footer" src="footer.png"></div>
<script>
const q=new URLSearchParams(location.search),id=q.get('case')||'B001',run=q.get('run')||'local';
const capture=document.getElementById('capture'),viewport=document.getElementById('viewport'),page=document.getElementById('page'),header=document.getElementById('header'),footer=document.getElementById('footer');
document.title='DC Fixture '+run+' '+id;capture.setAttribute('aria-label',document.title);
const axis=q.get('axis')||'vertical',reverse=q.get('direction')==='reverse',fixed=q.get('fixed')==='1',delay=Number(q.get('delay')||0),loadingDelay=Number(q.get('loadingDelay')||0);
let wheels=0,pending=0,maxPending=0,ready=false,loading=false;const wheelEvents=[];
if(axis==='horizontal'){page.src='horizontal.png';page.style.width='4500px';page.style.height='300px';}
header.hidden=footer.hidden=!fixed;if(fixed){page.style.marginTop='36px';page.style.marginBottom='28px';}
function state(){const r=capture.getBoundingClientRect();return {id,run,ready,axis,reverse,fixed,delay,loadingDelay,loading,wheels,wheelEvents,pending,maxPending,scrollX:viewport.scrollLeft,scrollY:viewport.scrollTop,rect:[r.x,r.y,r.width,r.height],screenX,screenY,outerWidth,outerHeight,innerWidth,innerHeight,scale:devicePixelRatio,uptime:performance.now()};}
function report(){return fetch('/state/'+id,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(state())});}
page.addEventListener('load',async()=>{await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));if(reverse){if(axis==='vertical')viewport.scrollTop=1800;else viewport.scrollLeft=1800;}ready=true;await report();if(q.get('capture')==='1'){document.getElementById('status').textContent='正在验证 '+id;const response=await fetch('/capture/'+id,{method:'POST',headers:{'X-DeskCapture-Fixture-Control':q.get('controlKey')||''}});const job=await response.json();const timer=setInterval(async()=>{const value=await(await fetch('/job/'+job.id)).json();if(value.finished){clearInterval(timer);document.getElementById('status').textContent=(value.success?'已通过 ':'未通过 ')+id+(value.error?' '+value.error:'');}},500);}});
viewport.addEventListener('wheel',e=>{wheels++;const unit=e.deltaMode===1?16:e.deltaMode===2?300:1,delta=(axis==='vertical'?e.deltaY:(e.deltaX||e.deltaY))*unit,event={number:wheels,delta,receivedAt:performance.now(),applied:false};wheelEvents.push(event);if(delay){e.preventDefault();pending++;maxPending=Math.max(maxPending,pending);setTimeout(()=>{if(axis==='vertical')viewport.scrollTop+=delta;else viewport.scrollLeft+=delta;event.position=axis==='vertical'?viewport.scrollTop:viewport.scrollLeft;event.applied=true;event.appliedAt=performance.now();pending--;report();},delay);}else{setTimeout(()=>{event.position=axis==='vertical'?viewport.scrollTop:viewport.scrollLeft;event.applied=true;event.appliedAt=performance.now();report();},250);}report();},{passive:false});
viewport.addEventListener('scroll',()=>{if(loadingDelay&&wheels){page.style.opacity='0.2';loading=true;setTimeout(()=>{page.style.opacity='1';loading=false;report();},loadingDelay);}report();});setInterval(report,100);
</script>'''

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(root), **kwargs)
    def log_message(self, *_):
        pass
    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == '/fixture':
            body = HTML.encode(); self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
        elif path.startswith('/state/'):
            body=json.dumps(states.get(path.rsplit('/',1)[-1], {})).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        elif path.startswith('/job/'):
            body=json.dumps(jobs.get(path.rsplit('/',1)[-1],{})).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        elif path in ['/vertical.png','/horizontal.png','/header.png','/footer.png']:
            super().do_GET()
        else:self.send_error(404)
    def do_POST(self):
        path=urllib.parse.urlsplit(self.path).path
        if path.startswith('/capture/'):
            if self.headers.get('X-DeskCapture-Fixture-Control')!=control_key:self.send_error(403);return
            case=path.rsplit('/',1)[-1]
            if not case.isalnum() or not case.startswith(('B','S')):self.send_error(400);return
            job_id=uuid.uuid4().hex
            if not job_lock.acquire(blocking=False):self.send_error(409);return
            jobs[job_id]={'id':job_id,'case':case,'finished':False}
            def run():
                try:
                    log=root/('capture-job-'+job_id+'.log')
                    with log.open('w') as output:
                        result=subprocess.run([str(repository/'scripts/check-browser-scroll.sh'),str(root),case,'--existing-build'],cwd=repository,stdout=output,stderr=subprocess.STDOUT)
                    text=log.read_text(); error=''
                    if result.returncode:
                        lines=text.splitlines();error=next((line for line in lines if '"error"' in line),lines[-1] if lines else 'runner failed')
                    jobs[job_id].update({'finished':True,'success':result.returncode==0,'returnCode':result.returncode,'error':error,'log':str(log)})
                    subprocess.run([sys.executable,str(repository/'scripts/report-browser-cases.py')],cwd=repository,capture_output=True)
                except Exception as error:jobs[job_id].update({'finished':True,'success':False,'error':str(error)})
                finally:job_lock.release()
            threading.Thread(target=run,daemon=True).start()
            body=json.dumps({'id':job_id}).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
        if not path.startswith('/state/') or int(self.headers.get('Content-Length','0'))>65536:
            self.send_error(400);return
        name=path.rsplit('/',1)[-1]
        if not name.isalnum():self.send_error(400);return
        try: value=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
        except ValueError:self.send_error(400);return
        states[name]=value
        (root/('state-'+name+'.json')).write_text(json.dumps(value,indent=2))
        self.send_response(204);self.end_headers()

server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'server.json').write_text(json.dumps({'pid':__import__('os').getpid(),'url':'http://127.0.0.1:'+str(server.server_port),'started':time.time(),'controlKey':control_key},indent=2))
print('http://127.0.0.1:'+str(server.server_port),flush=True)
server.serve_forever()
