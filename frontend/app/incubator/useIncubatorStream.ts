"use client";
import {useEffect,useState} from "react";
import {useQueryClient} from "@tanstack/react-query";
import {incubatorQuery} from "@/lib/api-queries";
import {parseWorkflow,workflowKey} from "./evaluation";
import {parseRuns} from "./model";
import {connectWorkflowStream,type StreamStatus} from "./stream-connection";
export function useIncubatorStream() {
 const client=useQueryClient(),[connection,setConnection]=useState<StreamStatus>("connecting");
 const [,setClock]=useState(0);
 useEffect(()=>{const timer=setInterval(()=>setClock(n=>n+1),1000);return()=>clearInterval(timer);},[]);
 useEffect(()=>{
  let active=true;
  const close=connectWorkflowStream(()=>new EventSource("/api/incubator/assignments/stream"),async message=>{
   const data=JSON.parse(message),runs=parseRuns(data),evaluations=parseWorkflow(data);
   await Promise.all([client.cancelQueries({queryKey:incubatorQuery.queryKey}),client.cancelQueries({queryKey:workflowKey})]);
   if(active){client.setQueryData(incubatorQuery.queryKey,runs);client.setQueryData(workflowKey,evaluations);}
  },setConnection);
  return()=>{active=false;close();};
 },[client]);
 return connection;
}
