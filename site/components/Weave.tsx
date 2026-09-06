// Zig and telar, above the headline. Every few seconds Zig sends a pulse down
// the warp into telar; the shuttle crosses the loom, the weft is laid, and the
// tile rings outward. One CSS clock drives every part, so the pieces stay in
// step without JavaScript.

const CYCLE = "6s";

export default function Weave() {
  return (
    <div
      className="weave pointer-events-none absolute top-[3.75rem] left-1/2 z-10 hidden -translate-x-1/2 items-center lg:flex"
      style={{ ["--cycle" as string]: CYCLE }}
      aria-hidden="true"
    >
      <div className="weave-source tile-face relative flex h-[76px] w-[76px] items-center justify-center rounded-[22px] border border-line bg-panel">
        <span className="weave-ring weave-ring-source" />
        <img src="/brand/stack/zig.svg" alt="" width={40} height={37} draggable={false} />
      </div>

      <div className="weave-warp relative mx-1 h-[76px] w-[96px]">
        <span className="weave-thread" style={{ top: "34%" }} />
        <span className="weave-thread" style={{ top: "50%" }} />
        <span className="weave-thread" style={{ top: "66%" }} />
        <span className="weave-spark" style={{ top: "34%", ["--lag" as string]: "0s" }} />
        <span className="weave-spark" style={{ top: "50%", ["--lag" as string]: "0.12s" }} />
        <span className="weave-spark" style={{ top: "66%", ["--lag" as string]: "0.24s" }} />
      </div>

      <div className="weave-target tile-face relative flex h-[92px] w-[92px] items-center justify-center rounded-[26px] border border-line bg-panel">
        <span className="weave-ring weave-ring-target" />
        <svg viewBox="0 0 64 64" width={64} height={64} className="weave-loom">
          <g fill="none" stroke="var(--overlay-1)" strokeWidth="3" strokeLinecap="round">
            <path d="M14 12 V28 M14 36 V52" />
            <path d="M23 12 V52" />
            <path d="M32 12 V28 M32 36 V52" />
            <path d="M41 12 V52" />
            <path d="M50 12 V28 M50 36 V52" />
          </g>
          <path className="weave-weft" d="M6 32 H19 M27 32 H37 M45 32 H50" fill="none" stroke="var(--accent)" strokeWidth="3" strokeLinecap="round" pathLength={1} />
          <path className="weave-shuttle" d="M49 32 L55 27.5 L61 32 L55 36.5 Z" fill="var(--accent)" />
        </svg>
      </div>
    </div>
  );
}
