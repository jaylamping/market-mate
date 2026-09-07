export const ticketCardStyles = {
  grid: "grid auto-rows-fr grid-cols-[repeat(auto-fill,minmax(min(100%,18rem),1fr))] gap-5",
  surface: "group flex h-full min-h-80 w-full min-w-0 flex-col items-start rounded-xl border border-border bg-card p-5 text-left text-card-foreground transition-colors hover:border-primary/60 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring",
  title: "mt-4 line-clamp-3 text-base font-medium leading-snug",
  preview: "mb-5 mt-3 line-clamp-3 text-sm leading-relaxed text-muted-foreground",
  footer: "mt-auto w-full space-y-1 border-t border-border pt-3 text-xs text-muted-foreground",
};
