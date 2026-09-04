import Loom from "@/components/Loom";
import PaneLink from "@/components/client/PaneLink";

export default function Hero() {
  return (
    <div data-loom className="relative flex h-full min-h-[30rem] flex-col overflow-hidden">
      <div className="absolute inset-0">
        <Loom />
      </div>

      <div className="relative mt-auto">
        <div className="pointer-events-none absolute inset-x-0 -top-24 bottom-0 bg-gradient-to-t from-ink via-ink/85 to-transparent" />
        <div data-loom-copy className="relative px-6 pt-10 pb-10 md:px-10 lg:px-12 lg:pb-12">
          <h1 className="display-sm max-w-[24ch] text-[clamp(1.5rem,2.5vw,2.25rem)] rise" style={{ ["--delay" as string]: "200ms" }}>
            A terminal runtime for coding agents.
          </h1>

          <p className="prose-measure mt-5 text-[17px] leading-relaxed text-subtext rise md:text-[19px]" style={{ ["--delay" as string]: "520ms" }}>
            Telar holds every agent session under tension, like threads on a loom. Close the lid, kill the client,
            come back tomorrow. The runtime kept the work.
          </p>

          <div className="mt-8 flex flex-wrap items-center gap-5 rise" style={{ ["--delay" as string]: "760ms" }}>
            <PaneLink
              to="install"
              className="inline-flex items-center rounded-sm bg-peach px-5 py-3 font-mono text-[14px] font-medium text-ink transition-colors hover:bg-mauve"
            >
              Install telar
            </PaneLink>
            <a
              href="https://github.com/adriangs1996/telar"
              className="font-mono text-[14px] text-subtext underline decoration-line underline-offset-6 transition-colors hover:text-text hover:decoration-overlay-1"
            >
              Read the source
            </a>
          </div>

          <p className="prose-measure mt-10 hidden font-mono text-[12.5px] leading-relaxed text-overlay-1 rise lg:block" style={{ ["--delay" as string]: "1200ms" }}>
            This page is one telar window. Scroll, or press <kbd className="rounded-sm border border-line px-1 text-subtext">j</kbd>{" "}
            and <kbd className="rounded-sm border border-line px-1 text-subtext">k</kbd>, to move between its panes.{" "}
            <kbd className="rounded-sm border border-line px-1 text-subtext">?</kbd> lists the keys.
          </p>
        </div>
      </div>
    </div>
  );
}
