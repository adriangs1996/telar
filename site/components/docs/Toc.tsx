"use client";

import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";

type Entry = { id: string; text: string; depth: number };

// The page's own headings, read from the rendered article so the MDX source
// stays the one place they are written.
export default function Toc() {
  const pathname = usePathname();
  const [entries, setEntries] = useState<Entry[]>([]);
  const [active, setActive] = useState("");

  useEffect(() => {
    const headings = Array.from(document.querySelectorAll<HTMLHeadingElement>(".doc h2[id], .doc h3[id]"));
    // A heading's text without its self-link.
    const text = (heading: HTMLHeadingElement) =>
      Array.from(heading.childNodes)
        .filter((node) => !(node instanceof Element && node.classList.contains("docs-anchor")))
        .map((node) => node.textContent)
        .join("");
    setEntries(headings.map((heading) => ({ id: heading.id, text: text(heading), depth: heading.tagName === "H2" ? 2 : 3 })));
    const observer = new IntersectionObserver(
      (observed) => {
        const visible = observed.filter((entry) => entry.isIntersecting).map((entry) => entry.target.id);
        if (visible.length) setActive(visible[0]);
      },
      { rootMargin: "0px 0px -70% 0px" },
    );
    headings.forEach((heading) => observer.observe(heading));
    return () => observer.disconnect();
  }, [pathname]);

  if (!entries.length) return null;

  return (
    <nav aria-label="On this page" className="docs-toc">
      <p className="docs-sidebar-heading">On this page</p>
      {entries.map((entry) => (
        <a key={entry.id} href={`#${entry.id}`} title={entry.text} data-depth={entry.depth} data-active={entry.id === active}>
          {entry.text}
        </a>
      ))}
    </nav>
  );
}
