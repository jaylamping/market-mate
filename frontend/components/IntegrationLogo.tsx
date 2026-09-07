import Image from "next/image";

export function IntegrationLogo({ provider }: { provider: "alpaca" | "openrouter" | "cursor" }) {
  return <span aria-hidden="true" className="inline-flex size-7 shrink-0 items-center justify-center">
    {provider === "cursor" ? <><Image src="/integrations/cursor-light.svg" alt="" width={28} height={28} className="size-7 object-contain dark:hidden"/><Image src="/integrations/cursor-dark.svg" alt="" width={28} height={28} className="hidden size-7 object-contain dark:block"/></> : provider === "alpaca" ? <Image src="/integrations/alpaca.png" alt="" width={28} height={28} className="size-7 object-contain"/> : <>
      <Image src="/integrations/openrouter-light.svg" alt="" width={28} height={28} className="size-7 object-contain dark:hidden"/>
      <Image src="/integrations/openrouter-dark.svg" alt="" width={28} height={28} className="hidden size-7 object-contain dark:block"/>
    </>}
  </span>;
}
