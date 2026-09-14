-- Osaka Jade: production chrome and Ghostty terminal colors.
return require("telar").theme({
	base = "vesper",
	colors = {
		accent = "#A8C98C",
		-- panel_bg = "#17241E",
		panel_bg = "default",
		surface0 = "#203128",
		surface1 = "#304A39",
		surface_dim = "#111C18",
		overlay0 = "#52675A",
		overlay1 = "#7F9785",
		text = "#D5DDCC",
		subtext0 = "#9DAA9B",
		mauve = "#C3CEA0",
		green = "#91B99A",
		yellow = "#D4B477",
		red = "#E58C85",
		blue = "#8FAF9F",
		teal = "#91B7B0",
		peach = "#A8C98C",
	},
	-- Terminal colors used by Ghostty's Osaka Jade theme.
	terminal = {
		foreground = "#D5DDCC",
		background = "#111C18",
		cursor_color = "#C5E6A0",
		cursor_text_color = "#111C18",
		palette = {
			"#17241E", "#E58C85", "#91B99A", "#D4B477",
			"#8FA9B3", "#B3A1B5", "#91B7B0", "#BBC8B5",
			"#7F9785", "#F0A29A", "#A8C98C", "#D0C398",
			"#ABC1C8", "#C4B3C5", "#ADD0C5", "#D5DDCC",
		},
	},
})
