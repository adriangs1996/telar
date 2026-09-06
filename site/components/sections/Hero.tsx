import CopyCommand from "@/components/CopyCommand";
import Loom from "@/components/Loom";
import Tiles from "@/components/Tiles";
import Weave from "@/components/Weave";

const HEADLINE: (string | { em: string })[][] = [
  ["Your", "agents", "run", { em: "inside" }, "it."],
  ["Not", "beside", "it."],
];

// The loom's threads span the right of the hero behind everything. The word
// is embroidered only inside the empty box beside the copy, under the
// headline, so the two never overlap.
export default function Hero() {
  let index = 0;

  return (
    <section id="top" className="relative">
      <Tiles />
      <Weave />
      <div data-loom className="rails relative overflow-hidden">
        <div className="loom-mask pointer-events-none absolute inset-y-0 right-0 hidden w-[62%] lg:block lg:pointer-events-auto">
          <Loom />
        </div>

      <div className="relative px-5 pt-20 pb-16 md:px-8 md:pt-28 md:pb-20">
        <p className="eyebrow rise" style={{ ["--delay" as string]: "0ms" }}>
          a terminal runtime for coding agents
        </p>

        <h1 className="display relative z-10 mt-8 text-[clamp(2.75rem,7.4vw,6.6rem)]">
          {HEADLINE.map((line, row) => (
            <span key={row} className="block">
              {line.map((word) => {
                const style = { ["--w" as string]: index++ };
                return typeof word === "string" ? (
                  <span key={`${row}-${word}`} className="word mr-[0.22em]" style={style}>
                    {word}
                  </span>
                ) : (
                  <em key={`${row}-${word.em}`} className="word mr-[0.22em]" style={style}>
                    {word.em}
                  </em>
                );
              })}
            </span>
          ))}
        </h1>

        <div className="mt-8 lg:grid lg:grid-cols-[minmax(0,38rem)_1fr] lg:gap-16">
          <div>
            <p className="measure rise text-[17px] leading-relaxed text-subtext md:text-[19px]" style={{ ["--delay" as string]: "700ms" }}>
              telar owns the pty, the TLS path and the history of every coding agent you start. Close the lid, kill the
              client, come back tomorrow. The runtime kept the work, and it can tell you what happened while you were away.
            </p>

            <div className="rise mt-10" style={{ ["--delay" as string]: "900ms" }}>
              <CopyCommand command="git clone https://github.com/adriangs1996/telar && cd telar && zig build run" />
              <p className="mt-3 font-mono text-[11.5px] tracking-[0.06em] text-overlay-1">
                macOS · Linux · MIT · Zig 0.16 · built from source, no binary release yet ·{" "}
                <a href="#install" className="text-subtext underline decoration-line underline-offset-4 transition-colors hover:text-text">
                  full install →
                </a>
              </p>
            </div>
          </div>

          <div data-loom-word aria-hidden="true" className="pointer-events-none hidden min-h-[16rem] lg:mr-12 lg:block" />
        </div>
      </div>
      </div>
    </section>
  );
}
