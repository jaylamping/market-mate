import { ExternalLink } from "lucide-react";

export function ModelLink({ provider, id, name }: { provider: "openrouter" | "cursor"; id: string; name: string }) {
  const href = provider === "openrouter"
    ? `https://openrouter.ai/${id.split("/").map(encodeURIComponent).join("/")}`
    : id.startsWith("claude-") ? "https://claude.com/product/overview"
    : id.startsWith("gemini-") ? "https://ai.google.dev/gemini-api/docs/models"
    : /^(gpt-|o[134](?:-|$))/.test(id) ? "https://developers.openai.com/api/docs/models"
    : id.startsWith("grok-") ? "https://docs.x.ai/developers/models"
    : "https://cursor.com/docs/models-and-pricing";
  return <a href={href} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1.5 rounded-sm font-semibold text-primary underline-offset-4 hover:underline focus-visible:outline-2 focus-visible:outline-ring" title={provider === "cursor" ? "View provider model information (opens in a new tab)" : "View model on OpenRouter (opens in a new tab)"}>
    {name}<ExternalLink aria-hidden="true" className="size-3.5 shrink-0"/><span className="sr-only"> (opens in a new tab)</span>
  </a>;
}
