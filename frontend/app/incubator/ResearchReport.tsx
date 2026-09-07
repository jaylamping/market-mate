import type {Report} from "./model";
export function reportList(title: string, items: string[], ordered = false) {
  const List=ordered ? "ol" : "ul";
  return <section className="space-y-2"><h3 className="font-medium">{title}</h3><List className={`${ordered ? "list-decimal" : "list-disc"} space-y-2 pl-5 text-sm text-muted-foreground`}>{items.map((item,i)=><li key={i}>{ordered ? item.replace(/^\s*\d{1,3}[.)]\s+/, "") : item}</li>)}</List></section>;
}
export function ResearchReport({report}:{report:Report}) {
  return <div className="space-y-6 break-words">
    <section className="space-y-2"><h3 className="font-medium">Hypothesis</h3><p className="text-sm leading-relaxed">{report.hypothesis}</p></section>
    <div className="grid gap-6 lg:grid-cols-2">{reportList("Evidence needed",report.evidence_gaps)}{reportList("Proposed experiment",report.experiment,true)}</div>
    <section className="space-y-2"><h3 className="font-medium">Reject the hypothesis if…</h3><p className="text-sm text-muted-foreground">{report.falsification_rule}</p></section>
    {reportList("Limitations",report.limitations)}
  </div>;
}
