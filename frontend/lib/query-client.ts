import { QueryClient } from "@tanstack/react-query";

export function makeQueryClient() {
  return new QueryClient({ defaultOptions: {
    queries: { staleTime: 15_000, retry: false, refetchOnWindowFocus: false },
    mutations: { retry: false },
  } });
}
