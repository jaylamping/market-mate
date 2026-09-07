export type EvaluationStatus="queued"|"evaluating"|"awaiting_clarification"|"needs_input"|"advance"|"refine"|"close"|"failed"|"indeterminate"|"superseded";
export type Evaluation={id:string;run_key:string;revision:number;report:import("./model").Report;created_at:string;status:EvaluationStatus;owner_answer:string|null;steps:{sequence:number;kind:"evaluation"|"clarification";model:string;created_at:string;state:string;finished_at:string|null;detail:{decision?:string;reason?:string;question?:string|null;answer?:string}}[];experiment:null|{id:string;title:string;status:"awaiting_setup";created_at:string}};
export const workflowKey=["incubator-workflow"] as const;
export const evaluationLabel:Record<EvaluationStatus,string>={queued:"Awaiting evaluation",evaluating:"Evaluating",awaiting_clarification:"Awaiting clarification",needs_input:"Needs your input",advance:"Advanced to experiment",refine:"Needs refinement",close:"Not advancing",failed:"Evaluation stopped",indeterminate:"Evaluation outcome unknown",superseded:"Earlier report revision"};
export function parseWorkflow(value:unknown):Evaluation[]{
 if(!value||typeof value!=="object"||!Array.isArray((value as {evaluations:unknown}).evaluations))throw Error("Workflow unavailable");
 const rows=(value as {evaluations:Evaluation[]}).evaluations;
 for(const row of rows){if(!row||typeof row.id!=="string"||typeof row.run_key!=="string"||!Number.isInteger(row.revision)||!(row.status in evaluationLabel)||!Array.isArray(row.steps)||!row.report||typeof row.report.hypothesis!=="string")throw Error("Invalid workflow");}
 return rows;
}
export async function getWorkflow(){const r=await fetch("/api/incubator/workflow",{cache:"no-store"});if(!r.ok)throw Error("Workflow unavailable");return parseWorkflow(await r.json());}
