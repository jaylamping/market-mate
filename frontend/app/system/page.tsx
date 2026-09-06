import { ApiHydration } from "../ApiHydration";
import { SystemPage } from "./SystemPage";
export const metadata = { title: "System | Market Mate" };
export const dynamic = "force-dynamic";
export default function Page() { return <ApiHydration source="paper"><SystemPage /></ApiHydration>; }
