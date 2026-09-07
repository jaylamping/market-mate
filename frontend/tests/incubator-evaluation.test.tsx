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
