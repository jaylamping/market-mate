"use client";
import {useEffect,useState} from "react";
import {useQueryClient} from "@tanstack/react-query";
import {incubatorQuery} from "@/lib/api-queries";
import {parseRuns} from "./model";
export function useIncubatorStream() {
 const client=useQueryClient(),[connected,setConnected]=useState(false);
 const [,setClock]=useState(0);
 useEffect(()=>{const timer=setInterval(()=>setClock(n=>n+1),1000);return()=>clearInterval(timer);},[]);
 useEffect(()=>{
  const stream=new EventSource("/api/incubator/assignments/stream");
  stream.onmessage=async event=>{
   try{const runs=parseRuns(JSON.parse(event.data));await client.cancelQueries({queryKey:incubatorQuery.queryKey});client.setQueryData(incubatorQuery.queryKey,runs);setConnected(true);}
   catch{setConnected(false);}
  };
  stream.onerror=()=>setConnected(false);
  return()=>stream.close();
 },[client]);
 return connected;
}
