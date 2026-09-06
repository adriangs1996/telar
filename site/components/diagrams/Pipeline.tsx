// The path a byte takes, from CLAUDE.md. Every stage is telar's own. Output
// travels the top rail left to right and becomes glyphs; a keystroke travels
// the bottom rail back to the child.

const STAGES = [
  ["child", "the agent's process"],
  ["pty", "telar owns it"],
  ["vt.Terminal", "one per pane"],
  ["cells", "ui.Buffer"],
  ["your terminal", "screen diff"],
];

export default function Pipeline() {
  return (
    <div className="figure p-5 md:p-7">
      <div className="relative">
        <div className="relative h-px bg-line">
          {[0, 0.6, 1.2, 1.8, 2.4].map((delay) => (
            <span key={delay} className="packet" style={{ ["--delay" as string]: `${delay}s`, ["--dur" as string]: "3s" }} />
          ))}
        </div>

        <ul className="relative -mt-3.5 flex justify-between">
          {STAGES.map(([name, note]) => (
            <li key={name} className="flex w-1/5 flex-col items-center text-center">
              <span className="rounded-sm border border-line bg-surface px-2.5 py-1 font-mono text-[11.5px] text-text">{name}</span>
              <span className="mt-2 hidden font-mono text-[10.5px] text-overlay-1 sm:block">{note}</span>
            </li>
          ))}
        </ul>

        <div className="relative mt-10 h-px bg-line">
          {[0.3, 1.9].map((delay) => (
            <span key={delay} className="packet" data-dir="left" style={{ ["--delay" as string]: `${delay}s`, ["--dur" as string]: "2.2s" }} />
          ))}
        </div>
        <div className="mt-3 flex justify-between font-mono text-[10.5px] text-overlay-1">
          <span>
            <span className="text-mint">●</span> keystroke, back to the child in microseconds
          </span>
          <span>
            <span className="text-peach">●</span> output, one byte to one glyph
          </span>
        </div>
      </div>

      <p className="mt-6 border-t border-line pt-4 font-mono text-[12px] leading-relaxed text-subtext">
        The emulator decides what a screen <span className="text-text">is</span>, so telar never parses a child&apos;s escape
        sequences. The diff is the last step before bytes leave, so anything that changes what you see changes the buffer,
        never the output stream.
      </p>
    </div>
  );
}
