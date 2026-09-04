"use client";

import { useEffect, useRef } from "react";

// The hero loom. Grey warp threads span the pane under tension. A steel
// needle embroiders the word "telar" on them in satin stitch, one letter per
// second: short stitches laid side by side across each stroke, the thread
// running from the needle's eye to the last stitch. Moving the pointer across
// the warp plucks the threads.

type Thread = { x: number; bornAt: number; pluckAt: number; pluckAmp: number };

type Pt = { x: number; y: number };

type Stitch = { a: Pt; b: Pt; shade: number };

type Stroke = { points: Pt[]; total: number; stitches: Stitch[] };

type Move =
  | { kind: "hop"; from: Pt; to: Pt; start: number; duration: number }
  | { kind: "draw"; stroke: Stroke; start: number; duration: number }
  | { kind: "hold"; at: Pt; start: number; duration: number };

const GAP = 18;
const THREAD_WIDTH = 1.5;
const THREAD = "#343434";
const TENSION_UNTIL = 1000;
const LETTER_TIME = 1000;
const HOP_TIME = 220;
const LETTER_REST = 220;
const SPACING = 0.14;
const FRESH = 14;

const SHADES = ["#ffc799", "#f4b98a", "#ffd2a8"];
const FRESH_SHADE = "#fff1df";
const NEEDLE_STEEL = "#dcdcdc";
const NEEDLE_EDGE = "#8c8c8c";

function easeOutBack(t: number): number {
  const c = 1.70158;
  return 1 + (c + 1) * Math.pow(t - 1, 3) + c * Math.pow(t - 1, 2);
}

function easeInOut(t: number): number {
  return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
}

// Letters live in a unit box: advance 1, x-height 1, ascender 1.42, y up.
// Each letter is a list of strokes in the order the needle sews them.
function arc(cx: number, cy: number, r: number, from: number, to: number, steps = 28): Pt[] {
  const out: Pt[] = [];
  for (let i = 0; i <= steps; i++) {
    const a = ((from + ((to - from) * i) / steps) * Math.PI) / 180;
    out.push({ x: cx + r * Math.cos(a), y: cy + r * Math.sin(a) });
  }
  return out;
}

const HOOK = arc(0.62, 0.3, 0.2, 180, 340);

const LETTERS: Record<string, Pt[][]> = {
  t: [
    [{ x: 0.42, y: 1.42 }, { x: 0.42, y: 0.3 }, ...HOOK.slice(1)],
    [{ x: 0.14, y: 1.0 }, { x: 0.76, y: 1.0 }],
  ],
  e: [[{ x: 0.12, y: 0.52 }, { x: 0.8, y: 0.52 }, ...arc(0.46, 0.52, 0.34, 0, 322).slice(1)]],
  l: [[{ x: 0.42, y: 1.42 }, { x: 0.42, y: 0.3 }, ...HOOK.slice(1)]],
  a: [
    [{ x: 0.8, y: 1.0 }, { x: 0.8, y: 0.0 }],
    arc(0.46, 0.5, 0.34, 0, 360, 40),
  ],
  r: [
    [{ x: 0.3, y: 1.0 }, { x: 0.3, y: 0.0 }],
    arc(0.62, 0.62, 0.32, 180, 40),
  ],
};

const WORD = "telar";

// Deterministic jitter so the stitches keep their shape from frame to frame.
function noise(seed: number): number {
  const x = Math.sin(seed * 12.9898 + 78.233) * 43758.5453;
  return x - Math.floor(x);
}

// The point a distance `s` along a polyline, and the direction there.
function along(points: Pt[], s: number): { at: Pt; dir: Pt } {
  let walked = 0;
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1];
    const b = points[i];
    const len = Math.hypot(b.x - a.x, b.y - a.y);
    if (walked + len >= s || i === points.length - 1) {
      const t = len === 0 ? 1 : Math.max(0, Math.min(1, (s - walked) / len));
      return {
        at: { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t },
        dir: { x: (b.x - a.x) / (len || 1), y: (b.y - a.y) / (len || 1) },
      };
    }
    walked += len;
  }
  return { at: points[0], dir: { x: 1, y: 0 } };
}

// Satin stitch: one short stitch across the stroke every `pitch` pixels,
// leaning a little so the thread catches the light the way satin does.
function stitch(points: Pt[], width: number, pitch: number, seed: number): Stroke {
  let total = 0;
  for (let i = 1; i < points.length; i++) {
    total += Math.hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y);
  }

  const lean = (22 * Math.PI) / 180;
  const stitches: Stitch[] = [];
  const count = Math.max(1, Math.floor(total / pitch));
  for (let i = 0; i <= count; i++) {
    const s = Math.min(total, i * pitch);
    const { at, dir } = along(points, s);
    const nx = -dir.y * Math.cos(lean) - dir.x * Math.sin(lean);
    const ny = -dir.y * Math.sin(lean) + dir.x * Math.cos(lean);
    const half = (width / 2) * (0.96 + noise(seed + i) * 0.08);
    const slide = (noise(seed * 3 + i) - 0.5) * 0.7;
    const cx = at.x + dir.x * slide;
    const cy = at.y + dir.y * slide;
    stitches.push({
      a: { x: cx - nx * half, y: cy - ny * half },
      b: { x: cx + nx * half, y: cy + ny * half },
      shade: Math.floor(noise(seed * 7 + i) * SHADES.length),
    });
  }

  return { points, total, stitches };
}

export default function Loom({ className = "" }: { className?: string }) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) {
      return;
    }

    const ctx = canvas.getContext("2d");
    if (!ctx) {
      return;
    }

    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const start = performance.now();
    // The copy block below the word, when the hero marks one: the word keeps
    // clear of it and lines up with its left edge.
    const copy = canvas.closest("[data-loom]")?.querySelector<HTMLElement>("[data-loom-copy]") ?? null;
    let threads: Thread[] = [];
    let moves: Move[] = [];
    let strokeWidth = 20;
    let pitch = 3;
    let width = 0;
    let height = 0;
    let frame = 0;
    let running = false;
    let lastMouseX: number | null = null;

    // Lay the word out for this size and rebuild the needle's schedule. The
    // schedule keeps its timing across resizes; only the geometry moves.
    const layoutWord = () => {
      const padding = copy ? parseFloat(getComputedStyle(copy).paddingLeft) || 24 : 24;
      const copyTop = copy ? height - copy.offsetHeight : height * 0.55;
      const top = height * 0.1;
      const bottom = copyTop - 36;
      const room = Math.max(80, bottom - top);
      const advance = WORD.length + (WORD.length - 1) * SPACING;
      const unit = Math.min((width - padding * 2) / advance, (room / 1.42) * 0.8);
      const baseline = (top + bottom) / 2 + unit * 0.71;
      strokeWidth = Math.max(6, unit * 0.16);
      pitch = Math.max(2.2, strokeWidth * 0.085);

      const toPixels = (index: number, p: Pt): Pt => ({
        x: padding + (index * (1 + SPACING) + p.x) * unit,
        y: baseline - p.y * unit,
      });

      const schedule: Move[] = [];
      let clock = start + TENSION_UNTIL + 300;
      let needle: Pt = { x: -40, y: baseline - unit * 0.7 };
      for (let index = 0; index < WORD.length; index++) {
        const strokes = LETTERS[WORD[index]].map((points, n) =>
          stitch(points.map((p) => toPixels(index, p)), strokeWidth, pitch, index * 10 + n)
        );
        const letterLength = strokes.reduce((sum, stroke) => sum + stroke.total, 0);
        for (const stroke of strokes) {
          schedule.push({ kind: "hop", from: needle, to: stroke.points[0], start: clock, duration: HOP_TIME });
          clock += HOP_TIME;
          const duration = (LETTER_TIME * stroke.total) / letterLength;
          schedule.push({ kind: "draw", stroke, start: clock, duration });
          clock += duration;
          needle = stroke.points[stroke.points.length - 1];
        }
        schedule.push({ kind: "hold", at: needle, start: clock, duration: LETTER_REST });
        clock += LETTER_REST;
      }
      moves = schedule;
    };

    const layout = () => {
      const rect = canvas.getBoundingClientRect();
      width = rect.width;
      height = rect.height;
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.floor(width * dpr);
      canvas.height = Math.floor(height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

      const count = Math.max(1, Math.floor((width - 12) / GAP));
      const inset = (width - (count - 1) * GAP) / 2;
      threads = Array.from({ length: count }, (_, i) => ({
        x: inset + i * GAP,
        bornAt: threads[i]?.bornAt ?? start + i * 14,
        pluckAt: threads[i]?.pluckAt ?? -1e9,
        pluckAmp: threads[i]?.pluckAmp ?? 0,
      }));

      layoutWord();
      if (reduced) {
        draw(start + 1e6);
      }
    };

    const drawThread = (thread: Thread, now: number) => {
      const age = now - thread.bornAt;
      if (age < 0) {
        return;
      }

      const grow = Math.min(1, age / 700);
      const drawn = height * (reduced ? 1 : easeOutBack(grow));
      const settle = Math.max(0, age - 700);
      const tension = reduced ? 0 : Math.exp(-settle / 900) * Math.sin(settle / 45) * 2.2;
      const pluckAge = now - thread.pluckAt;
      const pluck = reduced || pluckAge > 1400 ? 0 : Math.exp(-pluckAge / 380) * Math.sin(pluckAge / 28) * thread.pluckAmp;
      const sway = tension + pluck;

      ctx.beginPath();
      ctx.moveTo(thread.x, 0);
      if (sway === 0) {
        ctx.lineTo(thread.x, drawn);
      } else {
        ctx.bezierCurveTo(thread.x + sway, drawn * 0.33, thread.x - sway * 0.6, drawn * 0.66, thread.x, drawn);
      }
      ctx.strokeStyle = THREAD;
      ctx.lineWidth = THREAD_WIDTH;
      ctx.lineCap = "round";
      ctx.stroke();
    };

    const drawStitches = (stroke: Stroke, count: number, fresh: number) => {
      ctx.lineWidth = pitch * 1.1;
      ctx.lineCap = "round";
      for (let shade = 0; shade < SHADES.length; shade++) {
        ctx.beginPath();
        for (let i = 0; i < count - fresh; i++) {
          const s = stroke.stitches[i];
          if (s.shade !== shade) {
            continue;
          }
          ctx.moveTo(s.a.x, s.a.y);
          ctx.lineTo(s.b.x, s.b.y);
        }
        ctx.strokeStyle = SHADES[shade];
        ctx.stroke();
      }

      if (fresh > 0) {
        ctx.beginPath();
        for (let i = Math.max(0, count - fresh); i < count; i++) {
          const s = stroke.stitches[i];
          ctx.moveTo(s.a.x, s.a.y);
          ctx.lineTo(s.b.x, s.b.y);
        }
        ctx.strokeStyle = FRESH_SHADE;
        ctx.stroke();
      }
    };

    // A steel needle, tip at the cloth, leaning up and to the right, with the
    // thread running from its eye back to the last stitch.
    const drawNeedle = (tip: Pt, lift: number, threadFrom: Pt | null) => {
      const ux = 0.53;
      const uy = -0.85;
      const vx = -uy;
      const vy = ux;
      const length = Math.max(44, Math.min(70, strokeWidth * 1.6));
      const px = tip.x + ux * lift;
      const py = tip.y + uy * lift;
      const mid = 0.42 * length;
      const eyeAt = 0.84 * length;

      ctx.beginPath();
      ctx.moveTo(px, py);
      ctx.lineTo(px + ux * mid + vx * 1.8, py + uy * mid + vy * 1.8);
      ctx.lineTo(px + ux * length + vx * 1.3, py + uy * length + vy * 1.3);
      ctx.lineTo(px + ux * length - vx * 1.3, py + uy * length - vy * 1.3);
      ctx.lineTo(px + ux * mid - vx * 1.8, py + uy * mid - vy * 1.8);
      ctx.closePath();
      ctx.fillStyle = NEEDLE_STEEL;
      ctx.fill();
      ctx.strokeStyle = NEEDLE_EDGE;
      ctx.lineWidth = 0.6;
      ctx.stroke();

      const eye = { x: px + ux * eyeAt, y: py + uy * eyeAt };
      ctx.save();
      ctx.translate(eye.x, eye.y);
      ctx.rotate(Math.atan2(uy, ux));
      ctx.beginPath();
      ctx.ellipse(0, 0, 2.6, 0.9, 0, 0, Math.PI * 2);
      ctx.fillStyle = "#101010";
      ctx.fill();
      ctx.restore();

      if (threadFrom) {
        const sag = 6 + lift * 0.4;
        ctx.beginPath();
        ctx.moveTo(eye.x, eye.y);
        ctx.quadraticCurveTo((eye.x + threadFrom.x) / 2, Math.max(eye.y, threadFrom.y) + sag, threadFrom.x, threadFrom.y);
        ctx.strokeStyle = SHADES[0];
        ctx.lineWidth = 1.6;
        ctx.lineCap = "round";
        ctx.stroke();
      }
    };

    // Everything sewn so far, plus where the needle is right now.
    const drawWord = (now: number) => {
      let needle: { tip: Pt; lift: number } | null = null;
      let lastStitch: Pt | null = null;

      for (const move of moves) {
        if (move.kind !== "draw") {
          continue;
        }

        const { stitches } = move.stroke;
        if (now >= move.start + move.duration || reduced) {
          drawStitches(move.stroke, stitches.length, 0);
          lastStitch = stitches[stitches.length - 1].b;
        } else if (now >= move.start) {
          const progress = (now - move.start) / move.duration;
          const count = Math.max(1, Math.floor(progress * stitches.length));
          drawStitches(move.stroke, count, FRESH);
          const current = stitches[count - 1];
          const pierce = count % 2 === 0 ? current.a : current.b;
          lastStitch = count % 2 === 0 ? current.b : current.a;
          needle = { tip: pierce, lift: 2 + 4 * Math.abs(Math.sin(now / 38)) };
        }
      }

      if (reduced) {
        return;
      }

      if (!needle) {
        for (const move of moves) {
          if (now < move.start || now >= move.start + move.duration) {
            continue;
          }
          if (move.kind === "hop") {
            const p = easeInOut((now - move.start) / move.duration);
            needle = {
              tip: { x: move.from.x + (move.to.x - move.from.x) * p, y: move.from.y + (move.to.y - move.from.y) * p },
              lift: 14 + 10 * Math.sin(p * Math.PI),
            };
          } else if (move.kind === "hold") {
            needle = { tip: move.at, lift: 12 };
          }
        }
      }

      const last = moves[moves.length - 1];
      if (!needle && last && now >= last.start + last.duration && last.kind === "hold") {
        needle = { tip: { x: last.at.x + 26, y: last.at.y - 10 }, lift: 16 };
      }

      if (needle) {
        drawNeedle(needle.tip, needle.lift, lastStitch);
      }
    };

    const draw = (now: number) => {
      ctx.clearRect(0, 0, width, height);

      for (const thread of threads) {
        drawThread(thread, now);
      }

      drawWord(now);

      const fade = ctx.createLinearGradient(0, 0, 0, height * 0.18);
      fade.addColorStop(0, "rgba(16,16,16,0.85)");
      fade.addColorStop(1, "rgba(16,16,16,0)");
      ctx.fillStyle = fade;
      ctx.fillRect(0, 0, width, height * 0.18);
    };

    const loop = (now: number) => {
      draw(now);
      frame = running ? requestAnimationFrame(loop) : 0;
    };

    // The loop only runs while the loom is on screen.
    const visibility = new IntersectionObserver(([entry]) => {
      const visible = entry.isIntersecting;
      if (visible && !running && !reduced) {
        running = true;
        frame = requestAnimationFrame(loop);
      } else if (!visible && running) {
        running = false;
        cancelAnimationFrame(frame);
        frame = 0;
      }
    });

    const onMove = (event: PointerEvent) => {
      const rect = canvas.getBoundingClientRect();
      const x = event.clientX - rect.left;
      if (lastMouseX !== null) {
        const lo = Math.min(lastMouseX, x);
        const hi = Math.max(lastMouseX, x);
        const now = performance.now();
        for (const thread of threads) {
          if (thread.x > lo && thread.x <= hi && now - thread.pluckAt > 120) {
            thread.pluckAt = now;
            thread.pluckAmp = Math.min(6, 2 + Math.abs(x - lastMouseX) / 6);
          }
        }
      }
      lastMouseX = x;
    };

    const onLeave = () => {
      lastMouseX = null;
    };

    const observer = new ResizeObserver(layout);
    observer.observe(canvas);
    if (copy) {
      observer.observe(copy);
    }
    layout();
    if (!reduced) {
      visibility.observe(canvas);
      canvas.addEventListener("pointermove", onMove);
      canvas.addEventListener("pointerleave", onLeave);
    }

    return () => {
      running = false;
      cancelAnimationFrame(frame);
      visibility.disconnect();
      observer.disconnect();
      canvas.removeEventListener("pointermove", onMove);
      canvas.removeEventListener("pointerleave", onLeave);
    };
  }, []);

  return <canvas ref={ref} aria-hidden="true" className={`block h-full w-full ${className}`} />;
}
