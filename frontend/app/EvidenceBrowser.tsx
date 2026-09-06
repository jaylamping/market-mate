"use client";

import { useState } from "react";
import { ArrowUpRight, Search, Archive } from "lucide-react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import type { Stage1SurfacesModel } from "./Stage1Surfaces";
import { displayTime } from "./overview-model";

export function EvidenceBrowser({ snapshots }: { snapshots: Stage1SurfacesModel["snapshots"] }) {
  const [query, setQuery] = useState("");
  const search = query.trim().toLowerCase();
  const manifests = snapshots.latest_manifests.filter(m => `${m.cycle_key} ${m.cycle_kind} ${m.evidence_state}`.toLowerCase().includes(search));
  const records = snapshots.latest_snapshots.filter(s => `${s.snapshot_id} ${s.snapshot_kind} ${s.payload_digest}`.toLowerCase().includes(search));
  const empty = <div className="evidence-empty"><Archive aria-hidden="true"/><strong>{search ? "No matching evidence" : "No evidence recorded yet"}</strong><p>{search ? "Try a cycle name, snapshot kind, or a shorter identifier." : "Preserved records will appear here when research evidence is recorded."}</p></div>;
  return <section className="evidence-dock" id="evidence" aria-labelledby="evidence-heading">
    <header className="evidence-title"><div><h2 id="evidence-heading">Preserved evidence</h2><p>{snapshots.snapshot_count} snapshots · {snapshots.manifest_count} cycles on record</p></div><a className="text-link" href="/surfaces#snapshot-browser">View evidence details <ArrowUpRight aria-hidden="true"/></a></header>
    <Tabs defaultValue="cycles">
      <div className="evidence-toolbar"><TabsList aria-label="Evidence type"><TabsTrigger value="cycles">Research cycles</TabsTrigger><TabsTrigger value="snapshots">Snapshots</TabsTrigger></TabsList><label className="evidence-search"><Search aria-hidden="true"/><Input aria-label="Filter displayed evidence" value={query} onChange={e => setQuery(e.target.value)} placeholder="Filter displayed evidence…" /></label></div>
      <TabsContent value="cycles">
        <p className="table-context">Latest {snapshots.latest_manifests.length} cycles. Custody trust applies to the overall projection; completion is a separate measure.</p>
        {manifests.length ? <Table><TableHeader><TableRow><TableHead>Research cycle</TableHead><TableHead>Recorded as of</TableHead><TableHead>Completion</TableHead><TableHead>Snapshots</TableHead><TableHead><span className="sr-only">Inspect</span></TableHead></TableRow></TableHeader><TableBody>{manifests.map(m => <TableRow key={m.cycle_key}><TableCell><a className="cycle-link" href={`/surfaces#${encodeURIComponent(`cycle-${m.cycle_key}`)}`}>{m.cycle_key}</a><small>{m.cycle_kind.replaceAll("_", " ")}</small></TableCell><TableCell className="data-time">{displayTime(m.cycle_as_of)}</TableCell><TableCell><Badge variant="outline" className={m.evidence_state === "complete" ? "state-good" : "state-warning"}>{m.evidence_state}</Badge><small>{m.completion_state.replaceAll("_", " ")}</small></TableCell><TableCell className="data-number">{m.completed_snapshot_count} / {m.expected_snapshot_count}</TableCell><TableCell><a className="text-link" href={`/surfaces#${encodeURIComponent(`cycle-${m.cycle_key}`)}`} aria-label={`Inspect cycle ${m.cycle_key}`}>Inspect <ArrowUpRight aria-hidden="true"/></a></TableCell></TableRow>)}</TableBody></Table> : empty}
      </TabsContent>
      <TabsContent value="snapshots">
        <p className="table-context">Latest {snapshots.latest_snapshots.length} snapshots. Inventory is global; no relationship to a cycle is inferred.</p>
        {records.length ? <Table><TableHeader><TableRow><TableHead>Snapshot</TableHead><TableHead>Received</TableHead><TableHead>Payload digest</TableHead><TableHead><span className="sr-only">Inspect</span></TableHead></TableRow></TableHeader><TableBody>{records.map(s => <TableRow key={s.snapshot_id}><TableCell><strong>{s.snapshot_kind.replaceAll("_", " ")}</strong><small className="data-number">{s.snapshot_id}</small></TableCell><TableCell className="data-time">{displayTime(s.receipt_time)}</TableCell><TableCell><code title={s.payload_digest}>{s.payload_digest.slice(0, 16)}…</code></TableCell><TableCell><a className="text-link" href={`/surfaces#${encodeURIComponent(`snapshot-${s.snapshot_id}`)}`} aria-label={`Inspect snapshot ${s.snapshot_id}`}>Inspect <ArrowUpRight aria-hidden="true"/></a></TableCell></TableRow>)}</TableBody></Table> : empty}
      </TabsContent>
    </Tabs>
  </section>;
}
