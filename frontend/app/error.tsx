"use client";
import { Button } from "@/components/ui/button";
import { AlertTriangle } from "lucide-react";

export default function Error({ error, retry }: { error: Error & { digest?: string }; retry: () => void }) {
  return <main className="overview-state"><section className="overview-state-panel state-error" role="alert">
    <AlertTriangle aria-hidden="true" /><h1>Evidence is unavailable</h1>
    <p>The research service could not provide valid evidence. Check that the local services are running, then try again.</p>
    <p>Trust and system state cannot be confirmed while evidence is unavailable. Order authority remains none.</p>
    {error.digest && <small>Reference: {error.digest}</small>}
    <Button variant="outline" onClick={retry}>Retry evidence</Button>
  </section></main>;
}
