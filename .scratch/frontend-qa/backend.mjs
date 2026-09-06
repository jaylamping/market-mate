import http from 'node:http';
import fs from 'node:fs';
const fixture = JSON.parse(fs.readFileSync('frontend/tests/fixtures/stage1.json','utf8'));
http.createServer((req,res)=>{
 const mode=fs.readFileSync('.scratch/frontend-qa/mode','utf8').trim();
 res.setHeader('content-type','application/json');
 if (mode==='offline') { res.writeHead(503); res.end('{"error":"QA outage"}'); return; }
 const data=structuredClone(fixture);
 if(mode==='invalid') data.order_authority=true;
 if(mode==='empty') {
  for(const key of ['qualification','cost','cost_model']) data[key]={recorded:false,state:'not_recorded',detail:'No evidence recorded yet.'};
  data.snapshots={recorded:false,snapshot_count:0,manifest_count:0,latest_manifests:[],latest_snapshots:[]};
  data.checkpoints_verified=false;
  data.checkpoint_pack={recorded:false,checkpoint_count:0,head_position:null,verified_position:null,pending_events:null,state:'CHECKPOINT UNVERIFIED'};
 }
 if(mode==='negative') {
  data.qualification.net_mean_return_bps=-74; data.qualification.lcb_vs_cash_bps=0;
  data.qualification.lcb_vs_sp500_bps=null; data.qualification.sp500_comparator_required=false; data.qualification.meets_sp500_floor=null;
 }
 res.end(JSON.stringify(data));
}).listen(8092,'127.0.0.1',()=>console.log('QA evidence backend at 127.0.0.1:8092'));
