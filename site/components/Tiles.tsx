// Floating tiles hugging the rails beside the hero. Left: the agents telar
// recognizes, drawn with the marks the client embeds. Right: terminals that
// implement the kitty graphics protocol telar speaks, per the protocol's own
// list at sw.kovidgoyal.net/kitty/graphics-protocol. Decoration, so they sit
// just outside the content and only appear when the viewport leaves room.
//
// Marks: Claude, Codex and Pi from src/frontend/assets; Ghostty from
// github.com/ghostty-org/ghostty; kitty from sw.kovidgoyal.net/kitty; WezTerm
// from github.com/wez/wezterm; Konsole is KDE Breeze's utilities-terminal,
// the icon Konsole ships with; iTerm2 and Warp via simpleicons.org.

type Tile = {
  name: string;
  mark: string;
  side: "left" | "right";
  top: string;
  /// How far outside the rail the tile sits, in rem. On narrower screens the
  /// tile stops short of the viewport edge instead.
  offset: number;
  size: number;
  glyph?: number;
  delay: number;
  duration: number;
};

const TILES: Tile[] = [
  { name: "Claude Code", mark: "/brand/providers/claude.png", side: "left", top: "14%", offset: 9, size: 88, delay: 0, duration: 7.2 },
  { name: "Codex", mark: "/brand/providers/codex.png", side: "left", top: "44%", offset: 12, size: 80, delay: 1.4, duration: 8.6 },
  { name: "Pi", mark: "/brand/providers/pi.svg", side: "left", top: "72%", offset: 9.5, size: 84, delay: 2.6, duration: 7.9 },
  { name: "Ghostty, the tested host terminal", mark: "/brand/stack/ghostty.png", side: "right", top: "9%", offset: 9, size: 84, glyph: 0.68, delay: 0.7, duration: 8.2 },
  { name: "kitty", mark: "/brand/stack/kitty.svg", side: "right", top: "26%", offset: 12.5, size: 76, glyph: 0.64, delay: 2.1, duration: 9.1 },
  { name: "WezTerm", mark: "/brand/stack/wezterm.svg", side: "right", top: "42%", offset: 8.5, size: 80, glyph: 0.72, delay: 3.3, duration: 7.6 },
  { name: "Konsole", mark: "/brand/stack/konsole.svg", side: "right", top: "58%", offset: 12.5, size: 72, glyph: 0.7, delay: 1.0, duration: 8.8 },
  { name: "iTerm2", mark: "/brand/stack/iterm2.svg", side: "right", top: "73%", offset: 9, size: 76, glyph: 0.6, delay: 2.8, duration: 8.1 },
  { name: "Warp", mark: "/brand/stack/warp.svg", side: "right", top: "88%", offset: 12, size: 70, glyph: 0.56, delay: 4.0, duration: 9.4 },
];

export default function Tiles() {
  return (
    <div className="pointer-events-none absolute inset-0 hidden 2xl:block" aria-hidden="true">
      <div className="relative mx-auto h-full max-w-[76rem]">
        {TILES.map((tile) => {
          const glyph = Math.round(tile.size * (tile.glyph ?? 0.58));
          return (
            <div
              key={tile.name}
              className="tile-float absolute"
              style={{
                top: tile.top,
                [tile.side]: `calc(-1 * min(${tile.offset}rem, (100vw - 76rem) / 2 - 0.75rem))`,
                ["--delay" as string]: `${tile.delay}s`,
                ["--dur" as string]: `${tile.duration}s`,
              }}
            >
              <div
                title={tile.name}
                className="tile-face pointer-events-auto flex items-center justify-center rounded-[22px] border border-line bg-panel"
                style={{ width: tile.size, height: tile.size }}
              >
                <img src={tile.mark} alt="" width={glyph} height={glyph} className="rounded-[14px]" draggable={false} />
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
