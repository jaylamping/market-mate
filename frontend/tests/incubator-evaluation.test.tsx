import test from "node:test";
import assert from "node:assert/strict";
import React from "react";
import {renderToStaticMarkup} from "react-dom/server";
import {OriginBadge} from "../app/incubator/OriginBadge";
import {ProgressFooter} from "../app/incubator/ProgressFooter";
import {parseWorkflow} from "../app/incubator/evaluation";
test("card origins distinguish owner, automatic agent, and legacy local runner",()=>{
 for(const [origin,label] of [["principal","You"],["agent","Agent"],["local_runner","Local runner"]] as const)assert.match(renderToStaticMarkup(<OriginBadge origin={origin}/>),new RegExp(`Created by ${label}`));
});
test("only active stage has stripes; stopped and waiting stages stay still",()=>{
 const markup=renderToStaticMarkup(<ProgressFooter steps={[{label:"Done",state:"complete"},{label:"Working",state:"active"},{label:"Failed",state:"failed"},{label:"Waiting",state:"pending"}]}/>);
 assert.equal((markup.match(/workflow-progress-active/g)??[]).length,1);assert.match(markup,/bg-destructive/);assert.match(markup,/h-9/);
});
test("malformed workflow snapshots cannot replace the known history",()=>{assert.deepEqual(parseWorkflow({evaluations:[]}),[]);for(const value of [null,{}, {evaluations:[{}]}])assert.throws(()=>parseWorkflow(value));});

import {QueryClient,QueryClientProvider} from "@tanstack/react-query";
import {ReportEvaluation} from "../app/incubator/EvaluationView";
import {WorkflowTimeline} from "../app/incubator/WorkflowTimeline";
import type {Evaluation} from "../app/incubator/evaluation";
import type {Run} from "../app/incubator/model";
const evaluations:Evaluation[]=[0,1].map(revision=>({id:String(revision+1),run_key:"sample",revision,created_at:"2026-09-07T01:00:00Z",status:"close",owner_answer:null,experiment:null,report:{hypothesis:"Test",experiment:["Test"],evidence_gaps:["Data"],limitations:["None measured"],falsification_rule:"Reject failure"},steps:[{sequence:1,kind:"evaluation",model:"v/m:free",created_at:"2026-09-07T01:01:00Z",state:"completed",finished_at:"2026-09-07T01:02:00Z",detail:{decision:"close",reason:`Reason for revision ${revision}`}}]}));
test("report evaluation follows the selected revision including the original",()=>{
 for(const revision of [0,1]){const html=renderToStaticMarkup(<QueryClientProvider client={new QueryClient()}><ReportEvaluation evaluations={evaluations} revision={revision}/></QueryClientProvider>);assert.match(html,new RegExp(`Reason for revision ${revision}`));assert.doesNotMatch(html,new RegExp(`Reason for revision ${1-revision}`));}
});
test("evaluation preserves detailed timeline timestamps while cards stay compact",()=>{
 const run={state:"completed",created_at:"2026-09-07T00:59:00Z",events:[{state:"dispatched",at:"2026-09-07T01:00:00Z"}]} as Run;
 const detailed=renderToStaticMarkup(<WorkflowTimeline run={run} evaluation={evaluations[0]}/>);
 assert.match(detailed,/dateTime="2026-09-07T01:01:00Z"/);assert.match(detailed,/dateTime="2026-09-07T01:02:00Z"/);
 assert.doesNotMatch(renderToStaticMarkup(<WorkflowTimeline run={run} evaluation={evaluations[0]} compact/>),/<time/);
});

import {ResearchReport} from "../app/incubator/ResearchReport";
import {parseReport} from "../app/incubator/model";
test("shared research and experiment report renderer supplies numbering once",()=>{
 const report={...evaluations[0].report,experiment:["1. First step","2) Second step","Third step"]};
 const html=renderToStaticMarkup(<ResearchReport report={report}/>);
 assert.match(html,/<ol /);assert.match(html,/<li>First step<\/li>/);assert.match(html,/<li>Second step<\/li>/);assert.doesNotMatch(html,/<li>[12][.)]/);
 assert.equal(report.experiment[0],"1. First step");
});
test("workflow and research use the same strict five-field report ingestion",()=>{
 const report=evaluations[0].report;
 assert.deepEqual(parseReport(report),report);
 for(const bad of [{...report,extra:true},{...report,experiment:"1. Test"},{...report,experiment:[{}]},{...report,limitations:[]},{...report,hypothesis:null}]){
  assert.throws(()=>parseReport(bad));assert.throws(()=>parseWorkflow({evaluations:[{...evaluations[0],report:bad}]}));
 }
});

import {experimentLabel,type Experiment,type ExperimentStatus} from "../app/incubator/evaluation";
import {experimentProgress} from "../app/incubator/ExperimentDetail";
test("live experiment states ingest and failures stay in their workflow stage",()=>{
 for(const state of Object.keys(experimentLabel) as ExperimentStatus[]){const experiment:Experiment={id:evaluations[0].id,title:"Diagnostic",created_at:evaluations[0].created_at,status:state,events:[]};assert.equal(parseWorkflow({evaluations:[{...evaluations[0],experiment}]})[0].experiment?.status,state);}
 const experiment:Experiment={id:"1",title:"Diagnostic",created_at:evaluations[0].created_at,status:"failed",events:[{sequence:1,state:"preparing",at:evaluations[0].created_at,detail:{}},{sequence:2,state:"ready",at:evaluations[0].created_at,detail:{}}]};
 const steps=experimentProgress(experiment);assert.equal(steps[1].state,"complete");assert.equal(steps[2].state,"failed");assert.equal(steps[3].state,"pending");
 assert.throws(()=>parseWorkflow({evaluations:[{...evaluations[0],experiment:{...experiment,events:[{state:"execute_live"}]}}]}));
});
test("refinement displays bounded progress and directs blocked revisions to Chat",()=>{
 const render=(e:Evaluation)=>renderToStaticMarkup(<QueryClientProvider client={new QueryClient()}><ReportEvaluation evaluations={[e]} revision={e.revision}/></QueryClientProvider>);
 const e:Evaluation={...evaluations[0],status:"refining",refinement_rounds_used:0};
 assert.match(render(e),/Refining · Round 1 of 2/);
 const blocked:Evaluation={...e,status:"needs_input",refinement_rounds_used:2,refinement_stop_reason:"Two rounds used"};
 assert.match(render(blocked),/Two rounds used/);assert.match(render(blocked),/Use Chat/);assert.doesNotMatch(render(blocked),/Answer and resume/);
 assert.equal(parseWorkflow({evaluations:[blocked]})[0].status,"needs_input");
 assert.throws(()=>parseWorkflow({evaluations:[{...blocked,refinement_rounds_used:3}]}));
});
