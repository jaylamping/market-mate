import { Stage1Surfaces } from "../Stage1Surfaces";
import { loadSurfaces } from "./load-surfaces";

export const dynamic = "force-dynamic";

export default async function Page() {
  return <Stage1Surfaces surfaces={await loadSurfaces()} />;
}
