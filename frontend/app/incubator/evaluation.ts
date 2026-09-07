import {parseReport,stateLabel,type Run} from "./model";
export type EvaluationStatus="refining"|"queued"|"evaluating"|"awaiting_clarification"|"needs_input"|"advance"|"refine"|"close"|"failed"|"indeterminate"|"superseded";
export type ExperimentStatus="setup_retry"|"experiment_retry"|"setup_question"|"awaiting_setup"|"preparing"|"clarifying"|"clarified"|"answered"|"awaiting_data"|"needs_input"|"ready"|"dispatching"|"running"|"completed"|"failed"|"indeterminate";
export type ExperimentEvent={sequence:number;state:ExperimentStatus;at:string;detail:Record<string,unknown>};
export type Experiment={setup_retry_available?:boolean;capacity_wait?:import("./model").CapacityWait|null;id:string;title:string;status:ExperimentStatus;created_at:string;snapshot_id?:string|null;dataset_class?:string|null;detail?:Record<string,unknown>;events?:ExperimentEvent[]};
export const experimentLabel:Record<ExperimentStatus,string>={setup_retry:"Setup retry queued",experiment_retry:"Retrying experiment agent",setup_question:"Waiting for clarification capacity",awaiting_setup:"Awaiting setup",preparing:"Checking setup",clarifying:"Clarifying research",clarified:"Research clarified",answered:"Input received",awaiting_data:"Awaiting data",needs_input:"Needs your input",ready:"Ready for experiment",dispatching:"Experiment agent",running:"Running diagnostic",completed:"Diagnostic complete",failed:"Experiment stopped",indeterminate:"Outcome unknown"};
export type Evaluation={capacity_wait?:import("./model").CapacityWait|null;refinement_rounds_used?:number;refinement_stop_reason?:string;refinement?:null|{round:number;state:string;reason:string|null;created_at:string;finished_at:string|null};id:string;run_key:string;revision:number;report:import("./model").Report;created_at:string;status:EvaluationStatus;owner_answer:string|null;steps:{sequence:number;kind:"evaluation"|"clarification";model:string;created_at:string;state:string;finished_at:string|null;detail:{decision?:string;reason?:string;question?:string|null;answer?:string}}[];experiment:null|Experiment};
export const workflowKey=["incubator-workflow"] as const;
export const evaluationLabel:Record<EvaluationStatus,string>={refining:"Refining",queued:"Awaiting evaluation",evaluating:"Evaluating",awaiting_clarification:"Awaiting clarification",needs_input:"Needs your input",advance:"Advanced to experiment",refine:"Needs refinement",close:"Not advancing",failed:"Evaluation stopped",indeterminate:"Evaluation outcome unknown",superseded:"Earlier report revision"};
export function parseWorkflow(value:unknown):Evaluation[]{
 if(!value||typeof value!=="object"||!Array.isArray((value as {evaluations:unknown}).evaluations))throw Error("Workflow unavailable");
 const rows=(value as {evaluations:Evaluation[]}).evaluations;
 for(const row of rows){if(!row||typeof row.id!=="string"||typeof row.run_key!=="string"||!Number.isInteger(row.revision)||!Object.hasOwn(evaluationLabel,row.status)||!Array.isArray(row.steps)||!row.report||typeof row.report.hypothesis!=="string")throw Error("Invalid workflow");
 parseReport(row.report);
 if(row.refinement_rounds_used!==undefined&&(!Number.isInteger(row.refinement_rounds_used)||row.refinement_rounds_used<0||row.refinement_rounds_used>2))throw Error("Invalid refinement count");
 if(row.refinement_stop_reason!==undefined&&typeof row.refinement_stop_reason!=="string")throw Error("Invalid refinement reason");
 if(row.refinement&&(![1,2].includes(row.refinement.round)||!["pending","completed","blocked","failed","indeterminate","superseded"].includes(row.refinement.state)||(row.refinement.reason!==null&&typeof row.refinement.reason!=="string")))throw Error("Invalid refinement");
 if(row.revision<0||!Number.isFinite(Date.parse(row.created_at))||(row.owner_answer!==null&&typeof row.owner_answer!=="string"))throw Error("Invalid workflow metadata");
 for(const step of row.steps){if(!step||!Number.isInteger(step.sequence)||!["evaluation","clarification"].includes(step.kind)||typeof step.model!=="string"||!Number.isFinite(Date.parse(step.created_at))||!["pending","completed","failed","indeterminate"].includes(step.state)||!step.detail||typeof step.detail!=="object")throw Error("Invalid workflow step");for(const field of ["reason","answer","decision","question"] as const){const v=step.detail[field];if(v!==undefined&&v!==null&&typeof v!=="string")throw Error("Invalid workflow detail");}}
 if(row.experiment!==null&&(!row.experiment||row.experiment.id!==row.id||typeof row.experiment.title!=="string"||!Object.hasOwn(experimentLabel,row.experiment.status)||!Number.isFinite(Date.parse(row.experiment.created_at))))throw Error("Invalid experiment ticket");
 if(row.experiment?.events!==undefined){if(!Array.isArray(row.experiment.events))throw Error("Invalid experiment events");for(const event of row.experiment.events){if(!event||!Number.isInteger(event.sequence)||!Object.hasOwn(experimentLabel,event.state)||!Number.isFinite(Date.parse(event.at))||!event.detail||typeof event.detail!=="object")throw Error("Invalid experiment event");}}
 }
 return rows;
}
export async function getWorkflow(){const r=await fetch("/api/incubator/workflow",{cache:"no-store",signal:AbortSignal.timeout(15_000)});if(!r.ok)throw Error("Workflow unavailable");return parseWorkflow(await r.json());}

export function experimentReason(value:unknown):string {
 if(typeof value!=="string")return "";
 const reasons:Record<string,string>={
  invalid_experiment_agent_response:"The model did not return a usable answer. The workflow stopped before continuing.",
  incomplete_agent_reply:"The model's answer was missing required fields. The workflow stopped before continuing.",
  experiment_agent_output_truncated:"The model reached its response limit before finishing its answer. The workflow stopped before continuing.",
 };
 return reasons[value]??value;
}

export function researchStatus(run:Run,evaluation?:Evaluation):string {
 return run.state==="completed"&&evaluation?.status==="advance"?"Advanced":stateLabel(run);
}

export function researchHasAdvanced(evaluation:Evaluation|undefined):boolean {
 return evaluation?.status==="advance"||!!evaluation?.experiment;
}

export type ExperimentOutcome="active"|"positive"|"negative"|"terrible"|"stopped";
export const experimentOutcomeLabel:Record<ExperimentOutcome,string>={active:"Active",positive:"Positive",negative:"Negative",terrible:"Terrible",stopped:"Stopped"};
export const experimentOutcomeOrder:ExperimentOutcome[]=["active","positive","negative","terrible","stopped"];

function metric(value:unknown):number|null {
 if(typeof value==="number"&&Number.isFinite(value))return value;
 if(typeof value==="string"&&/^-?\d+$/.test(value))return Number(value);
 return null;
}

export function experimentOutcome(experiment:Experiment):ExperimentOutcome {
 if(experiment.status==="failed"||experiment.status==="indeterminate")return "stopped";
 if(experiment.status!=="completed")return "active";
 const result=experiment.detail?.result;
 if(!result||typeof result!=="object")return "negative";
 const row=result as Record<string,unknown>;
 const net=metric(row.mean_next_open_net_bps);
 const cash=metric(row.mean_cash_bps);
 if(net===null||cash===null)return "negative";
 if(net>cash)return "positive";
 const bench=metric(row.mean_benchmark_next_open_bps);
 if(bench!==null&&net<cash&&net<bench)return "terrible";
 return "negative";
}

export const experimentOutcomeColor:Record<ExperimentOutcome,string>={
 active:"var(--muted-foreground)",
 positive:"var(--good)",
 negative:"var(--warning)",
 terrible:"var(--destructive)",
 stopped:"var(--destructive)",
};

export function visibleExperiments(evaluations:Evaluation[],filter:"all"|ExperimentOutcome):Evaluation[] {
 const tickets=evaluations.filter((evaluation):evaluation is Evaluation&{experiment:Experiment}=>!!evaluation.experiment&&(filter==="all"||experimentOutcome(evaluation.experiment)===filter));
 return tickets.sort((left,right)=>{
  const rank=experimentOutcomeOrder.indexOf(experimentOutcome(left.experiment))-experimentOutcomeOrder.indexOf(experimentOutcome(right.experiment));
  return rank||Date.parse(right.experiment.created_at)-Date.parse(left.experiment.created_at);
 });
}
