import type { ReactNode } from "react";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import "./command-ledger.css";
import "./supervisory-overview.css";
import { QueryProvider } from "./QueryProvider";
import { ThemeProvider } from "./ThemeProvider";
import { UsageWidget } from "@/components/UsageWidget";
import { WorkspaceStateProvider } from "@/components/WorkspaceState";
import "./agents-workspace.css";

const overviewFont = Geist({
  display: "swap",
  subsets: ["latin"],
  variable: "--font-overview",
});

const overviewMono = Geist_Mono({
  display: "swap",
  subsets: ["latin"],
  variable: "--font-overview-mono",
});

export const metadata = {
  title: "Market Mate — Supervisory Overview",
};

export default function RootLayout({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className={`${overviewFont.variable} ${overviewMono.variable}`}><ThemeProvider><QueryProvider><WorkspaceStateProvider><UsageWidget preview={process.env.MM_POC_PREVIEW === "1"} />{children}</WorkspaceStateProvider></QueryProvider></ThemeProvider></body>
    </html>
  );
}
