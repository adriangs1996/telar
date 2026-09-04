import type { Metadata } from "next";
import { Instrument_Sans, Martian_Mono } from "next/font/google";
import "./globals.css";

const martian = Martian_Mono({
  subsets: ["latin"],
  weight: ["300", "400", "500"],
  variable: "--font-martian",
  display: "swap",
});

const instrument = Instrument_Sans({
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  variable: "--font-instrument",
  display: "swap",
});

export const metadata: Metadata = {
  title: "telar",
  description:
    "A terminal runtime for coding agents. Close the lid, kill the client, and your agents are still working when you come back. This page is laid out like a telar session.",
  metadataBase: new URL("https://telar.dev"),
  openGraph: {
    title: "telar",
    description: "A terminal runtime for coding agents.",
    type: "website",
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${martian.variable} ${instrument.variable}`}>
      <body>{children}</body>
    </html>
  );
}
