import { CommandLedger, type CommandLedgerModel } from "./CommandLedger";

export const dynamic = "force-dynamic";

async function loadLedger(): Promise<CommandLedgerModel> {
  const base = process.env.BACKEND_URL ?? "http://127.0.0.1:8080";
  const response = await fetch(`${base}/command-ledger`, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`command ledger is unavailable (${response.status})`);
  }
  return (await response.json()) as CommandLedgerModel;
}

export default async function Home() {
  const ledger = await loadLedger();
  return <CommandLedger ledger={ledger} />;
}
