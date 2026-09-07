"use client";
import { useQuery } from "@tanstack/react-query";
import { surfacesQuery } from "../lib/api-queries";
import { SupervisoryOverview } from "./SupervisoryOverview";
import { Stage1Surfaces } from "./Stage1Surfaces";
import { WorkspacePage } from "./WorkspacePage";
import { RefreshQueries } from "./RefreshQueries";
export function ResearchPage({ details = false }: { details?: boolean }) {
  const query = useQuery(surfacesQuery);
  if (query.isError || !query.data) return <WorkspacePage title="Overview" description="Research evidence" activePage="/"><section className="workspace-panel"><div className="chart-empty" role="status"><h2>{query.isError ? "Evidence unavailable" : "Loading evidence…"}</h2><p>{query.isError ? "The latest evidence could not be fetched. Refresh to try again." : "Fetching the research snapshot."}</p><RefreshQueries label="Refresh evidence" queryKeys={[surfacesQuery.queryKey]} /></div></section></WorkspacePage>;
  return details ? <Stage1Surfaces surfaces={query.data} /> : <SupervisoryOverview surfaces={query.data} loadedAt={new Date(query.dataUpdatedAt).toISOString()} />;
}
