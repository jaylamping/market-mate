import { ApiHydration } from "../ApiHydration";
import { ResearchPage } from "../ResearchPage";
export const dynamic = "force-dynamic";
export default function Page() { return <ApiHydration source="surfaces"><ResearchPage details /></ApiHydration>; }
