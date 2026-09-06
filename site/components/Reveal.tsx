"use client";

import { useEffect, useRef } from "react";

type Props = { as?: "div" | "section" | "li"; className?: string; children: React.ReactNode; once?: boolean };

// Children fade and rise once the block enters the viewport. Each child can
// set `--i` to stagger. Animations inside the block (`.packet`) start at the
// same moment so a figure begins moving when it is seen, not before.
//
//   <Reveal className="grid">
//     <h2 style={{ "--i": 0 }}>…</h2>
//     <p style={{ "--i": 1 }}>…</p>
//   </Reveal>
export default function Reveal({ as = "div", className = "", children, once = true }: Props) {
  const ref = useRef<HTMLElement>(null);

  useEffect(() => {
    const element = ref.current;
    if (!element) {
      return;
    }

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          element.dataset.reveal = "in";
          if (once) {
            observer.disconnect();
          }
        } else if (!once) {
          element.dataset.reveal = "";
        }
      },
      { threshold: 0.18, rootMargin: "0px 0px -8% 0px" }
    );

    observer.observe(element);
    return () => observer.disconnect();
  }, [once]);

  const Tag = as as "div";
  return (
    <Tag ref={ref as React.RefObject<HTMLDivElement>} data-reveal="" className={className}>
      {children}
    </Tag>
  );
}
