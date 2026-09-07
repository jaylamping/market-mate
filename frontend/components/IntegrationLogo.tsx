import Image from "next/image";

export function IntegrationLogo({ provider }: { provider: string }) {
  return <span aria-hidden="true" className="inline-flex size-7 shrink-0 items-center justify-center">
    {provider === "cursor" ? <><Image src="/integrations/cursor-light.svg" alt="" width={28} height={28} className="size-7 object-contain dark:hidden"/><Image src="/integrations/cursor-dark.svg" alt="" width={28} height={28} className="hidden size-7 object-contain dark:block"/></> : provider === "alpaca" ? <Image src="/integrations/alpaca.png" alt="" width={28} height={28} className="size-7 object-contain"/> : provider === "openrouter" ? <>
      <Image src="/integrations/openrouter-light.svg" alt="" width={28} height={28} className="size-7 object-contain dark:hidden"/>
      <Image src="/integrations/openrouter-dark.svg" alt="" width={28} height={28} className="hidden size-7 object-contain dark:block"/>
    </> : <span className="rounded-full bg-primary/15 px-2 py-1 text-xs font-semibold text-primary">{provider.slice(0,2).toUpperCase()}</span>}
  </span>;
}
