// Floating tiles around the hero: the agents telar recognizes, drawn with the
// same marks the client embeds, and the stack it runs on. Positions are
// percentages of the hero so they keep clear of the headline, the copy and
// the embroidered word on any wide screen.

type Tile = {
  name: string;
  top: string;
  right: string;
  size?: number;
  mark?: string;
  label?: string;
  tone?: string;
  delay: number;
  duration: number;
};

const TILES: Tile[] = [
  { name: "Claude Code", top: "9%", right: "27%", mark: "/brand/providers/claude.png", size: 64, delay: 0, duration: 7.2 },
  { name: "Codex", top: "7%", right: "9%", mark: "/brand/providers/codex.png", size: 56, delay: 1.1, duration: 8.4 },
  { name: "Pi", top: "34%", right: "3.5%", mark: "/brand/providers/pi.svg", size: 60, delay: 2.3, duration: 7.8 },
  { name: "Ghostty, the tested host terminal", top: "46%", right: "7%", label: "ghostty", tone: "text-text", delay: 0.6, duration: 9 },
  { name: "Kitty graphics protocol", top: "78%", right: "3%", label: "kgp", tone: "text-mauve", delay: 1.8, duration: 8 },
  { name: "Zig 0.16", top: "84%", right: "19%", label: "zig", tone: "text-peach", delay: 2.9, duration: 7.4 },
  { name: "Lua configuration", top: "22%", right: "1.5%", label: "lua", tone: "text-teal", delay: 3.6, duration: 8.8 },
  { name: "SQLite history", top: "8%", right: "44%", label: "sqlite", tone: "text-mint", size: 52, delay: 4.2, duration: 9.6 },
];

export default function Tiles() {
  return (
    <div className="pointer-events-none absolute inset-0 hidden lg:block" aria-hidden="true">
      {TILES.map((tile) => {
        const size = tile.size ?? 56;
        return (
          <div
            key={tile.name}
            className="tile-float absolute"
            style={{
              top: tile.top,
              right: tile.right,
              ["--delay" as string]: `${tile.delay}s`,
              ["--dur" as string]: `${tile.duration}s`,
            }}
          >
            <div
              title={tile.name}
              className="tile-face pointer-events-auto flex items-center justify-center rounded-[18px] border border-line bg-panel font-mono"
              style={{ width: size, height: size }}
            >
              {tile.mark ? (
                <img src={tile.mark} alt="" width={size * 0.56} height={size * 0.56} className="rounded-[10px]" draggable={false} />
              ) : (
                <span className={`text-[11px] tracking-[0.04em] ${tile.tone ?? "text-subtext"}`}>{tile.label}</span>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
