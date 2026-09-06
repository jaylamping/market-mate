"use client";

import { useState } from "react";
import { ArrowDownUp, ArrowUpRight, CircleCheck, ClipboardList, Layers3, Search, Wallet } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { PaperSnapshot } from "./model";
import { activityLabel, matchesSymbol, money, ordersMatching, readable, timestamp } from "./presentation";

function EmptyState({ kind, filtered, clear }: { kind:"positions"|"orders"; filtered:boolean; clear:()=>void }) {
  const Icon = kind === "positions" ? Layers3 : ClipboardList;
  return <div className="grid justify-items-center gap-3 px-6 pt-9 pb-10 text-center [&_h3]:m-0 [&_h3]:text-sm [&_h3]:font-[550] [&_p]:m-0 [&_p]:max-w-[42ch] [&_p]:text-sm [&_p]:leading-[1.6] [&_p]:text-muted-foreground max-[600px]:px-4 max-[600px]:py-6"><span className="grid size-11 place-items-center rounded-[10px] bg-accent text-primary [&_svg]:w-5"><Icon aria-hidden="true" /></span><h3>{filtered ? "No matching records" : kind === "positions" ? "Your first position starts here" : "No orders on record yet"}</h3><p>{filtered ? "Try another symbol or clear the filters to see the available records." : kind === "positions" ? "Positions appear here after simulated orders fill in your Alpaca Paper account." : "As Paper orders arrive, follow their status and filled quantities here."}</p>{filtered ? <Button variant="outline" size="sm" onClick={clear}>Clear filters</Button> : <span className="mt-2 max-w-[45ch] text-xs text-muted-foreground">{kind === "positions" ? "Connected to your simulated account" : "Market Mate currently observes orders; it does not submit them."}</span>}</div>;
}

export function PaperWorkspace({ data }: { data: PaperSnapshot }) {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("all");
  const [activityFilter, setActivityFilter] = useState("all");
  const positions = data.positions.filter(p => matchesSymbol(p.symbol, query));
  const orders = ordersMatching(data.orders, query, status);
  const activities = data.activities.filter(a => activityFilter === "all" || (activityFilter === "fills" ? a.activity_type === "FILL" : a.activity_type !== "FILL"));
  const statuses = [...new Set(data.orders.map(o => o.status))].sort();
  const clear = () => {setQuery(""); setStatus("all");};
  const currency = data.account.currency;
  const restricted = data.account.account_blocked || data.account.trading_blocked;
  const rejected = data.orders.filter(o => o.status === "rejected").length;
  return <>
    <section className="mt-6 overflow-hidden rounded-[10px] border bg-card" aria-label="Simulated account summary">
      <div className="flex items-center justify-between gap-3 px-6 pt-5 [&>div]:flex [&>div]:items-center [&>div]:gap-2 [&_svg]:w-4 [&_svg]:text-primary [&>span]:text-xs [&>span]:text-muted-foreground max-[600px]:flex-col max-[600px]:items-start max-[600px]:px-4 max-[600px]:pt-4"><div><Wallet aria-hidden="true"/><h2>Account snapshot</h2></div><span>{currency} · Simulated funds</span></div>
      <dl className="m-0 grid grid-cols-3 gap-6 p-6 [&>div]:min-w-0 [&_dt]:text-xs [&_dt]:text-muted-foreground [&_dd]:my-2 [&_dd]:text-[27px] [&_dd]:font-[450] [&_dd]:tracking-[-0.025em] [&_dd]:tabular-nums [&_dd]:wrap-anywhere [&_small]:text-xs [&_small]:text-muted-foreground max-[600px]:grid-cols-1 max-[600px]:gap-5 max-[600px]:px-4 max-[600px]:py-5">
        <div><dt>Account equity</dt><dd>{money(data.account.equity,currency)}</dd><small>Total account value reported by Alpaca</small></div>
        <div><dt>Cash balance</dt><dd>{money(data.account.cash,currency)}</dd><small>Simulated cash in the account</small></div>
        <div><dt>Buying power</dt><dd>{money(data.account.buying_power,currency)}</dd><small>Broker-reported capacity; may include margin</small></div>
      </dl>
      <div className="flex flex-wrap gap-x-6 gap-y-3 border-t px-6 py-3 text-xs text-muted-foreground [&_span]:inline-flex [&_span]:items-center [&_span]:gap-2 [&_svg]:w-3.5 [&_svg]:text-[var(--good)] max-[600px]:px-4"><span><CircleCheck aria-hidden="true"/>Connection verified</span><span>Account status: <strong>{readable(data.account.status)}</strong></span><span>{data.positions.length} open {data.positions.length === 1 ? "position" : "positions"}</span></div>
    </section>
    {(restricted || rejected > 0) && <section className="mt-5 rounded-[10px] border border-[var(--warning)] px-5 py-4 [&_p]:mt-2 [&_p]:text-sm" aria-label="Paper account attention"><h2>Needs attention</h2>{restricted && <p>Alpaca reports an account or trading restriction. Review your Paper account in Alpaca.</p>}{rejected > 0 && <p>{rejected} rejected {rejected === 1 ? "order" : "orders"} in the latest {data.recent_limit} records. Inspect the Orders tab for details.</p>}</section>}
    <div className="mt-6 grid grid-cols-[minmax(0,1.8fr)_minmax(320px,1fr)] items-start gap-5 max-[1150px]:grid-cols-1">
      <section className="workspace-panel [&_table]:text-xs [&_th]:px-4 [&_th]:py-3 [&_td]:px-4 [&_td]:py-3 [&_[role=tabpanel]]:m-0 max-[600px]:[&_table]:min-w-[540px]" aria-label="Paper positions and orders">
        <Tabs defaultValue="positions">
          <div className="border-b px-5 py-4 [&_[role=tab]]:gap-2 [&_[role=tab]_span]:text-xs [&_[role=tab]_span]:text-muted-foreground max-[600px]:px-4"><TabsList aria-label="Account records"><TabsTrigger value="positions">Positions <span>{data.positions.length}</span></TabsTrigger><TabsTrigger value="orders">Orders <span>{data.orders.length}</span></TabsTrigger></TabsList></div>
          <div className="relative mx-5 mt-5 flex items-center gap-2 [&>svg]:absolute [&>svg]:left-3 [&>svg]:size-3.5 [&>svg]:text-muted-foreground [&_input]:min-w-0 [&_input]:pl-9 max-[600px]:mx-4 max-[600px]:mt-4"><Search aria-hidden="true"/><Input aria-label="Search account records by symbol" placeholder="Search by symbol…" value={query} onChange={e => setQuery(e.target.value)} />{query && <Button size="sm" variant="ghost" onClick={()=>setQuery("")}>Clear</Button>}</div>
          <TabsContent value="positions">
            <div className="flex flex-wrap items-center justify-between gap-3 p-5 [&>span]:text-xs [&>span]:text-muted-foreground max-[600px]:p-4"><h2>Open positions</h2><span>{positions.length} of {data.positions.length}</span></div>
            {positions.length ? <Table><TableHeader><TableRow><TableHead>Instrument</TableHead><TableHead>Quantity</TableHead><TableHead>Market value</TableHead><TableHead>Unrealized P&amp;L</TableHead></TableRow></TableHeader><TableBody>{positions.map(p => <TableRow key={p.symbol}><TableCell><strong>{p.symbol}</strong><small className="mt-1 block text-xs text-muted-foreground">{readable(p.asset_class)} · {p.side}</small></TableCell><TableCell className="tabular-nums whitespace-nowrap">{p.qty}</TableCell><TableCell className="tabular-nums whitespace-nowrap">{money(p.market_value,currency)}</TableCell><TableCell className={`tabular-nums whitespace-nowrap ${p.unrealized_pl === null ? "" : Number(p.unrealized_pl) < 0 ? "text-destructive" : Number(p.unrealized_pl) > 0 ? "text-[var(--good)]" : ""}`}>{money(p.unrealized_pl,currency)}</TableCell></TableRow>)}</TableBody></Table> : <EmptyState kind="positions" filtered={!!query.trim()} clear={clear}/>}
          </TabsContent>
          <TabsContent value="orders">
            <div className="flex flex-wrap items-center justify-between gap-3 p-5 [&>span]:text-xs [&>span]:text-muted-foreground max-[600px]:p-4"><h2>Recent orders</h2><label className="flex items-center gap-2 text-xs text-muted-foreground [&_select]:max-w-full [&_select]:rounded-[7px] [&_select]:border [&_select]:border-input [&_select]:bg-background [&_select]:px-3 [&_select]:py-2 [&_select]:text-foreground"><span>Status</span><select aria-label="Filter orders by status" value={status} onChange={e=>setStatus(e.target.value)}><option value="all">All statuses</option>{statuses.map(s=><option key={s} value={s}>{readable(s)}</option>)}</select></label></div>
            <p className="m-0 px-5 pb-3 text-xs text-muted-foreground">Showing {orders.length} of {data.orders.length} received · Latest {data.recent_limit} at most</p>
            {orders.length ? <Table><TableHeader><TableRow><TableHead>Order</TableHead><TableHead>Quantity / value</TableHead><TableHead>Status</TableHead><TableHead>Record</TableHead></TableRow></TableHeader><TableBody>{orders.map(o=><TableRow key={o.id}><TableCell><strong>{o.symbol}</strong><small className="mt-1 block text-xs text-muted-foreground">{o.side} · {readable(o.type)}</small></TableCell><TableCell className="tabular-nums whitespace-nowrap">{o.qty ?? (o.notional === null ? "Not reported" : money(o.notional,currency))}<small className="mt-1 block text-xs text-muted-foreground">{o.filled_qty} filled</small></TableCell><TableCell><Badge variant="outline" className={o.status === "rejected" ? "text-destructive" : ""}>{readable(o.status)}</Badge></TableCell><TableCell><details className="text-xs [&_summary]:cursor-pointer [&_summary]:text-primary [&_p]:my-2 [&_code]:mt-2 [&_code]:block [&_code]:max-w-60 [&_code]:wrap-anywhere [&_code]:whitespace-normal [&_code]:text-muted-foreground"><summary>Details</summary><p>{timestamp(o.submitted_at)}</p><code>{o.id}</code></details></TableCell></TableRow>)}</TableBody></Table> : <EmptyState kind="orders" filtered={!!query.trim() || status !== "all"} clear={clear}/>}
          </TabsContent>
          <p className="m-0 border-t px-5 py-4 text-xs leading-[1.6] text-muted-foreground">Paper results are simulated. They do not establish strategy qualification or realized profit.</p>
        </Tabs>
      </section>
      <section className="workspace-panel [&_.panel-heading>svg]:w-4 [&_.panel-heading>svg]:text-muted-foreground" aria-labelledby="paper-activity-heading">
        <header className="panel-heading"><div><h2 id="paper-activity-heading">Activity timeline</h2><p>Latest {data.recent_limit} records at most</p></div><ArrowDownUp aria-hidden="true"/></header>
        <div className="flex items-center gap-2 px-5 py-4 text-xs text-muted-foreground [&_select]:max-w-full [&_select]:rounded-[7px] [&_select]:border [&_select]:border-input [&_select]:bg-background [&_select]:px-3 [&_select]:py-2 [&_select]:text-foreground"><label htmlFor="paper-activity-filter">Show</label><select id="paper-activity-filter" value={activityFilter} onChange={e=>setActivityFilter(e.target.value)}><option value="all">All activity</option><option value="fills">Trade fills</option><option value="other">Other activity</option></select></div>
        {activities.length ? <ol className="m-0 list-none px-5 pt-2 pb-5 [&_li]:grid [&_li]:grid-cols-[24px_minmax(0,1fr)] [&_li]:gap-3 [&_li]:pb-6 [&_li:last-child]:pb-0">{activities.map(a=><li key={a.id}><span className="pt-0.5 text-primary [&_svg]:w-4"><ArrowUpRight aria-hidden="true"/></span><div className="[&_h3]:m-0 [&_h3]:text-sm [&_h3]:font-[550] [&>p]:mt-2 [&>p]:mb-3 [&>p]:text-xs [&>p]:text-muted-foreground"><div className="flex flex-wrap justify-between gap-2 [&>strong]:text-sm [&>strong]:font-medium"><h3>{activityLabel(a)}</h3>{a.net_amount !== null && <strong className="tabular-nums whitespace-nowrap">{money(a.net_amount,currency)}</strong>}</div><p>{a.transaction_time ? timestamp(a.transaction_time) : a.date ? `${a.date} · Date only` : "Time not reported"}</p>{(a.symbol || a.qty !== null || a.price !== null) && <div className="mb-3 flex flex-wrap gap-2 text-xs">{a.symbol && <span>{a.symbol}</span>}{a.qty !== null && <span>Qty {a.qty}</span>}{a.price !== null && <span>Price {money(a.price,currency)}</span>}</div>}<details className="text-xs [&_summary]:cursor-pointer [&_summary]:text-primary [&_p]:my-2 [&_code]:mt-2 [&_code]:block [&_code]:max-w-60 [&_code]:wrap-anywhere [&_code]:whitespace-normal [&_code]:text-muted-foreground"><summary>View record</summary><p>Provider type: {a.activity_type}</p><code>{a.id}</code></details></div></li>)}</ol> : <div className="p-5 [&_h3]:m-0 [&_h3]:text-sm [&_h3]:font-[550] [&_p]:text-sm [&_p]:leading-[1.6] [&_p]:text-muted-foreground"><h3>{activityFilter === "all" ? "No activity reported" : "No matching activity"}</h3><p>{activityFilter === "all" ? "Fills and account events will appear here as Alpaca reports them." : "Choose All activity to see the available account events."}</p></div>}
        <p className="m-0 border-t px-5 py-4 text-xs leading-[1.6] text-muted-foreground">Cash journals are account movements, not trading profit. Exercise and assignment records may arrive the next day.</p>
      </section>
    </div>
  </>;
}
