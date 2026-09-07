import json,re,time
from http.server import BaseHTTPRequestHandler,HTTPServer
from pathlib import Path
sql=Path('db/migrations/0068_openrouter_capacity.sql').read_text()
policy=json.loads(re.search(r"INSERT INTO openrouter_capacity_control\(policy\) VALUES\('(.+)'\);",sql).group(1))
models=[{'id':'fixture/free:free','name':'Fixture Free Model','context_length':32000,'pricing':{'prompt':'0','completion':'0'}},{'id':'fixture/paid','name':'Fixture Paid Model','context_length':32000,'pricing':{'prompt':'0.0000001','completion':'0.0000002'}}]
def capacity():return {'policy':policy,'free_used':742,'free_remaining':258,'minute_used':18,'in_flight':3,'queued':5,'next_eligible_at':None,'cooldown_until':None,'free_cooldown_until':None,'paid_used_nanos':0,'paid_reserved_nanos':0,'paid_attempts':0,'window_mode':'rolling_24h','history_status':'accounted'}
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def reply(self,value,status=200):
  data=json.dumps(value).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(data)
 def do_GET(self):
  if self.path=='/capacity':return self.reply(capacity())
  if self.path=='/openrouter/models':return self.reply({'models':models})
  if self.path=='/openrouter/routing':return self.reply({'revision':0,'legacy_revisions':[0,0],'models':[{'model_id':m['id'].split('/')[-1],'routes':[{'provider':'openrouter','model_id':m['id']}]} for m in models],'research_model':'free:free','setup_model':'free:free','experiment_model':'free:free','default_model':'free:free'})
  if self.path=='/openrouter/policy':return self.reply({'revision':0,'allowed_models':[m['id'] for m in models]})
  if self.path=='/openrouter/status':return self.reply({'provider':'openrouter','model_policy':'whitelist','inference_enabled':False,'state':'connected','checked_at_ms':int(time.time()*1000)})
  return self.reply({'error':'Fixture has no such endpoint'},503)
 def do_PUT(self):
  global policy
  value=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  if self.path=='/capacity' and value['expected_revision']==policy['revision']:
   policy=value['policy'];policy['revision']+=1;return self.reply(capacity())
  self.reply({'error':'conflict'},409)
HTTPServer(('127.0.0.1',18089),Handler).serve_forever()
