import { dehydrate, HydrationBoundary } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { makeQueryClient } from "../lib/query-client";
import { paperQuery, surfacesQuery } from "../lib/api-queries";
import { loadPaper } from "./paper/load-paper";
import { loadSurfaces } from "./surfaces/load-surfaces";

export async function ApiHydration({ source, children }: { source: "paper" | "surfaces"; children: ReactNode }) {
  const client = makeQueryClient();
  if (source === "paper") await client.prefetchQuery({ ...paperQuery, queryFn: loadPaper });
  else await client.prefetchQuery({ ...surfacesQuery, queryFn: loadSurfaces });
  return <HydrationBoundary state={dehydrate(client)}>{children}</HydrationBoundary>;
}
