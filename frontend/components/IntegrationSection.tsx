import type { ReactNode } from "react";
import { ChevronRight } from "lucide-react";
import { IntegrationLogo } from "./IntegrationLogo";
import { IntegrationStatus } from "./IntegrationStatus";
import { Button } from "./ui/button";

export function IntegrationSection({ provider, description, state, metric, action, children }: {
  provider: string;
  description: string;
  state?: string;
  metric?: ReactNode;
  action: { href: string; label: string };
  children: ReactNode;
}) {
  return <div id={provider} className="grid min-w-0 gap-4 border-b p-6 last:border-b-0">
    <div className="flex flex-wrap items-start justify-between gap-4">
      <div className="grid min-w-0 gap-2">
        <div className="flex flex-wrap items-center gap-3">
          <h3 className="inline-flex items-center gap-2.5 text-base font-semibold"><IntegrationLogo provider={provider}/>{provider}</h3>
          {state && <IntegrationStatus state={state}/>}
          {metric}
        </div>
        <p className="text-sm text-muted-foreground">{description}</p>
      </div>
      <Button asChild variant="outline" size="sm"><a href={action.href}>{action.label}</a></Button>
    </div>
    <div className="grid min-w-0 gap-3 text-sm [&>p]:max-w-prose [&>p]:text-muted-foreground">{children}</div>
  </div>;
}

export function IntegrationDisclosure({ title, id, children }: { title: string; id?: string; children: ReactNode }) {
  return <details id={id} className="group min-w-0">
    <summary className="flex w-fit max-w-full cursor-pointer list-none items-center gap-2 rounded-md py-1 text-sm font-medium text-primary outline-none hover:underline focus-visible:ring-2 focus-visible:ring-ring [&::-webkit-details-marker]:hidden">
      <ChevronRight aria-hidden="true" className="size-4 shrink-0 group-open:rotate-90"/>{title}
    </summary>
    <div className="grid min-w-0 gap-3 pt-4 text-sm [&>p]:max-w-prose [&>p]:text-muted-foreground [&>code]:break-all [&>code]:rounded-md [&>code]:bg-muted [&>code]:p-3 [&>code]:text-xs">{children}</div>
  </details>;
}
