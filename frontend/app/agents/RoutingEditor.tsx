"use client";
import {createContext,useContext,useRef,useState,type ReactNode} from "react";
import {useMutation,useQuery,useQueryClient} from "@tanstack/react-query";
import {modelRoutingQuery} from "@/lib/api-queries";
import {parseRouting,type RoutingPolicy} from "@/lib/model-routing";
function useEditor(){
 const client=useQueryClient(),query=useQuery(modelRoutingQuery);
 const [draft,setDraft]=useState<RoutingPolicy|null>(null);
 const saveInFlight=useRef(false);
 const policy=draft??query.data;
  const save=useMutation({retry:false,mutationFn:async(next:RoutingPolicy)=>{
    const response=await fetch("/api/openrouter/routing",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(next),signal:AbortSignal.timeout(20_000)});
    if(!response.ok)throw new Error(response.status===409?"Preferences changed elsewhere. Load the latest preferences before editing again.":"Could not save. Your changes are still here; check the provider connections and try again.");
    return parseRouting(await response.json());
  },onSuccess:value=>{client.setQueryData(modelRoutingQuery.queryKey,value);setDraft(null);void client.invalidateQueries({queryKey:["api","openrouter","policy"]});void client.invalidateQueries({queryKey:["api","cursor","policy"]});},onSettled:()=>{saveInFlight.current=false;}});
  const persist=(next:RoutingPolicy)=>{
    if(saveInFlight.current)return;
    saveInFlight.current=true;
    setDraft(next);
    save.mutate(next);
  };
  const conflict=save.isError&&save.error.message.startsWith("Preferences changed elsewhere");
  const reload=async()=>{const result=await query.refetch();if(result.isSuccess){setDraft(null);save.reset();}};
 return {query,policy,save,draft,persist,conflict,reload};
}
const Context=createContext<ReturnType<typeof useEditor>|null>(null);
export function RoutingEditor({children}:{children:ReactNode}){const value=useEditor();return <Context.Provider value={value}>{children}</Context.Provider>;}
export function useRoutingEditor(){const value=useContext(Context);if(!value)throw Error("Routing editor provider missing");return value;}
