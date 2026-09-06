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
    "A terminal runtime for coding agents. It owns the pty, the TLS path and the history of every agent you start. Close the lid, kill the client, come back: the runtime kept the work.",
  metadataBase: new URL("https://telar.dev"),
  openGraph: {
    title: "telar",
    description: "A terminal runtime for coding agents. Your agents run inside it, not beside it.",
    type: "website",
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${martian.variable} ${instrument.variable} ${serif.variable}`}>
      <body className="desk">
        {/* Apply the stored theme before the first paint so a returning visitor never sees Vesper flash. */}
        <script
          dangerouslySetInnerHTML={{
            __html:
              'try{var t=localStorage.getItem("telar.theme");if(t&&/^(vesper|catppuccin|tokyo-night|terminal)$/.test(t))document.documentElement.dataset.theme=t}catch(e){}',
          }}
        />
        {children}
      </body>
    </html>
  );
}
