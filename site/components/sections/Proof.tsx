"use client";

import { useEffect, useRef, useState } from "react";
import Reveal from "@/components/Reveal";

type Tile = { value: number; unit?: string; digits?: number; label: string; source: string };

// No stars, no installs. Numbers a build is allowed to fail on, from
// docs/engineering-invariants.md and docs/performance-gates.md.
const TILES: Tile[] = [
  { value: 0, label: "allocations on the interactive path in steady state", source: "engineering invariants" },
  { value: 60, unit: "Hz", label: "frame cap; an obsolete frame is folded, never queued", source: "engineering invariants" },
  { value: 58, unit: "fps", label: "floor for a 4K RGBA stream through telar into Ghostty", source: "graphics gate, CI" },
  { value: 10, unit: "%", label: "p99 regression that fails the build (5% at p50, 8% at p95)", source: "performance gates" },
];

function Count({ to, digits = 0 }: { to: number; digits?: number }) {
  const ref = useRef<HTMLSpanElement>(null);
  const [value, setValue] = useState(0);

  useEffect(() => {
    const element = ref.current;
    if (!element) {
      return;
    }

    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setValue(to);
      return;
    }

    let frame = 0;
    const observer = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting) {
        return;
      }

      observer.disconnect();
      const start = performance.now();
      const run = (now: number) => {
        const t = Math.min(1, (now - start) / 1100);
        const eased = 1 - Math.pow(1 - t, 3);
        setValue(to * eased);
        if (t < 1) {
          frame = requestAnimationFrame(run);
        }
      };
      frame = requestAnimationFrame(run);
    });

    observer.observe(element);
    return () => {
      observer.disconnect();
      cancelAnimationFrame(frame);
    };
  }, [to]);

  return <span ref={ref}>{value.toFixed(digits)}</span>;
}

export default function Proof() {
  return (
    <Reveal as="section" className="rails hairline grid md:grid-cols-4" aria-label="Engineering budgets">
      {TILES.map((tile, index) => (
        <div key={tile.label} className="tile" style={{ ["--i" as string]: index }}>
          <div className="tile-value text-text">
            <Count to={tile.value} digits={tile.digits} />
            {tile.unit ? <span className="ml-1 text-[0.55em] font-normal text-peach">{tile.unit}</span> : null}
          </div>
          <p className="mt-3 text-[14px] leading-snug text-subtext">{tile.label}</p>
          <p className="mt-3 font-mono text-[10.5px] tracking-[0.14em] text-overlay-0 uppercase">{tile.source}</p>
        </div>
      ))}
    </Reveal>
  );
}
