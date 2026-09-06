import { SupervisoryOverview } from "./SupervisoryOverview";
import { loadSurfaces } from "./surfaces/load-surfaces";

export const dynamic = "force-dynamic";

export default async function Page() {
  return <SupervisoryOverview surfaces={await loadSurfaces()} />;
}
