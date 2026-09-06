import { ApiHydration } from "../ApiHydration";
import { PaperPage } from "./PaperPage";
export const metadata = { title: "Paper | Market Mate" };
export const dynamic = "force-dynamic";
export default function Page() { return <ApiHydration source="paper"><PaperPage /></ApiHydration>; }
