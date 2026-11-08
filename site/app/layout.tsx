import type { Metadata } from "next";
import { Instrument_Sans, Instrument_Serif, Martian_Mono } from "next/font/google";
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

const serif = Instrument_Serif({
  subsets: ["latin"],
  weight: ["400"],
  style: ["italic"],
  variable: "--font-instrument-serif",
  display: "swap",
});

export const metadata: Metadata = {
  title: "telar",
  description:
    "A terminal emulator and multiplexer for coding agents. A runtime keeps your shells, editors and agents running in workspaces, tabs and panes, and the sidebar tells you which agent needs you.",
  metadataBase: new URL("https://telar.dev"),
  openGraph: {
    title: "telar",
    description: "One place to rule them all, and in the web bind them.",
    type: "website",
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${martian.variable} ${instrument.variable} ${serif.variable}`}>
      <body>
        {children}
      </body>
    </html>
  );
}
