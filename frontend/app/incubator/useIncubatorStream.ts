"use client";
import {useEffect,useState} from "react";
import {useQueryClient} from "@tanstack/react-query";
import {incubatorQuery} from "@/lib/api-queries";
import {parseWorkflow,workflowKey} from "./evaluation";
import {parseRuns} from "./model";
export function useIncubatorStream() {
 const client=useQueryClient(),[connected,setConnected]=useState(false);
 const [,setClock]=useState(0);
 useEffect(()=>{const timer=setInterval(()=>setClock(n=>n+1),1000);return()=>clearInterval(timer);},[]);
 useEffect(()=>{
  const stream=new EventSource("/api/incubator/assignments/stream");
  stream.onmessage=async event=>{
   try{const data=JSON.parse(event.data),runs=parseRuns(data),evaluations=parseWorkflow(data);await Promise.all([client.cancelQueries({queryKey:incubatorQuery.queryKey}),client.cancelQueries({queryKey:workflowKey})]);client.setQueryData(incubatorQuery.queryKey,runs);client.setQueryData(workflowKey,evaluations);setConnected(true);}
   catch{setConnected(false);}
  };
  stream.onerror=()=>setConnected(false);
  return()=>stream.close();
 },[client]);
 return connected;
}
