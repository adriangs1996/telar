"use client";

import { useEffect, useState } from "react";

const LINKS: [string, string][] = [
  ["#demo", "demo"],
  ["#why", "why"],
  ["#install", "install"],
  ["https://github.com/adriangs1996/telar/tree/main/docs", "docs"],
];

export default function Nav() {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header className="nav" data-scrolled={scrolled}>
      <div className="rails flex h-14 items-center justify-between px-5 md:px-8">
        <a href="#top" className="flex items-center gap-2.5 font-mono text-[14px] text-text">
          <img src="/brand/telar-icon-small.svg" alt="" width={22} height={22} />
          telar
        </a>
        <nav aria-label="Site" className="flex items-center gap-1 font-mono text-[11.5px] tracking-[0.12em] uppercase">
          {LINKS.map(([href, label]) => (
            <a key={href} href={href} className="hidden rounded-sm px-3 py-1.5 text-subtext transition-colors hover:text-text sm:block">
              {label}
            </a>
          ))}
          <a
            href="https://github.com/adriangs1996/telar"
            className="ml-2 flex items-center gap-2 rounded-sm border border-line px-3 py-1.5 text-subtext transition-colors hover:border-overlay-0 hover:text-text"
          >
            <svg width="13" height="13" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
              <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
            </svg>
            github
          </a>
          <a href="#install" className="ml-1 rounded-sm bg-peach px-3 py-1.5 font-medium text-ink transition-colors hover:bg-mauve">
            build
          </a>
        </nav>
      </div>
    </header>
  );
}
