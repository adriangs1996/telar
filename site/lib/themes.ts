export type ThemeName = "vesper" | "catppuccin" | "tokyo-night" | "terminal";

export const THEMES: { id: ThemeName; label: string; swatch: string[] }[] = [
  { id: "vesper", label: "Vesper", swatch: ["#101010", "#282828", "#ffc799", "#99ffe4", "#66ddcc"] },
  { id: "catppuccin", label: "Catppuccin Mocha", swatch: ["#1e1e2e", "#45475a", "#89b4fa", "#a6e3a1", "#94e2d5"] },
  { id: "tokyo-night", label: "Tokyo Night", swatch: ["#1a1b26", "#414868", "#7aa2f7", "#9ece6a", "#7dcfff"] },
  { id: "terminal", label: "Terminal", swatch: ["#000000", "#303030", "#5f87d7", "#5faf5f", "#5fafaf"] },
];
