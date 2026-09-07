import { Badge } from "./ui/badge";
import { Check, AlertTriangle, CircleAlert, LoaderCircle } from "lucide-react";

const states = {
  connected: { label: "Connected", tone: "success" },
  loading: { label: "Checking…", tone: "neutral" },
  not_configured: { label: "Setup needed", tone: "attention" },
  rate_limited: { label: "Rate limited", tone: "attention" },
  invalid_credentials: { label: "Check credentials", tone: "error" },
  credentials_rejected: { label: "Check credentials", tone: "error" },
} as const;
const styles = {
  success: "border-[var(--good)]/30 bg-[var(--good)]/10 text-[var(--good)]",
  attention: "border-[var(--warning)]/30 bg-[var(--warning)]/10 text-[var(--warning)]",
  error: "border-destructive/30 bg-destructive/10 text-destructive",
  neutral: "border-border bg-muted text-muted-foreground",
};
export function IntegrationStatus({ state }: { state: string }) {
  const status = states[state as keyof typeof states] ?? { label: "Unavailable", tone: "error" as const };
  const Icon = status.tone === "success" ? Check : status.tone === "attention" ? AlertTriangle : status.tone === "error" ? CircleAlert : LoaderCircle;
  return <Badge variant="outline" className={`gap-1.5 ${styles[status.tone]}`}><Icon aria-hidden="true"/>{status.label}</Badge>;
}
