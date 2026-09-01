import type { ReactNode } from "react";
import "./command-ledger.css";

export const metadata = {
  title: "Market Mate — Command Ledger",
};

export default function RootLayout({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
