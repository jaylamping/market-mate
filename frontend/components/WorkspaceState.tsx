"use client";
import { createContext, useContext, useState, type ReactNode } from "react";
import { createStore, useStore } from "zustand";
type Overlay =
  | { kind: "closed" }
  | { kind: "provider"; id: string }
  | { kind: "model"; id: string };
type WorkspaceState = {
  persona: string | null;
  overlay: Overlay;
  modelTab: string;
  search: string;
  setPersona: (id: string | null) => void;
  open: (overlay: Overlay) => void;
  setModelTab: (tab: string) => void;
  setSearch: (search: string) => void;
};
function createWorkspaceStore() {
  return createStore<WorkspaceState>()((set) => ({
    persona: null,
    overlay: { kind: "closed" },
    modelTab: "providers",
    search: "",
    setPersona: (persona) => set({ persona }),
    open: (overlay) => set({ overlay }),
    setModelTab: (modelTab) => set({ modelTab }),
    setSearch: (search) => set({ search }),
  }));
}
const Context = createContext<ReturnType<typeof createWorkspaceStore> | null>(
  null,
);
export function WorkspaceStateProvider({ children }: { children: ReactNode }) {
  const [store] = useState(createWorkspaceStore);
  return <Context.Provider value={store}>{children}</Context.Provider>;
}
export function useWorkspaceState<T>(
  selector: (state: WorkspaceState) => T,
): T {
  const store = useContext(Context);
  if (!store) throw Error("WorkspaceStateProvider is required");
  return useStore(store, selector);
}
