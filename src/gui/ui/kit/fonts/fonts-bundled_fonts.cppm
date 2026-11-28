export module telar.gui.ui.kit.fonts:bundled_fonts;

import telar.gui.qt;

export namespace telar::gui::qt {
  // Registers the fonts the GUI embeds the first time it runs.
  // Returns Telar Forma, JetBrains Mono and Nerd Font symbols in fallback order.
  const QStringList& bundledFonts();
}
