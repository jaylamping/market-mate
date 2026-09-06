"use client";

import { ThemeProvider as Provider, useTheme } from "next-themes";
import { useEffect, useState } from "react";
import { Monitor } from "lucide-react";

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  return <Provider attribute="class" defaultTheme="system" enableSystem storageKey="market-mate-theme" disableTransitionOnChange>{children}</Provider>;
}

export function ThemePicker() {
  const { theme, setTheme } = useTheme();
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  return (
    <label className="theme-picker">
      <Monitor aria-hidden="true" />
      <span className="sr-only">Color theme</span>
      <select aria-label="Color theme" value={mounted ? theme : "system"} onChange={event => setTheme(event.target.value)}>
        <option value="system">System theme</option>
        <option value="light">Light theme</option>
        <option value="dark">Dark theme</option>
      </select>
    </label>
  );
}
