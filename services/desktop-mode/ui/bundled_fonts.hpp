#pragma once

#include <QStringList>

namespace ui {
  // Registers the fonts the desktop ships, the same faces the GUI embeds, the first time it runs.
  // Returns their families in fallback order: the terminal face, then Nerd Font symbols.
  const QStringList &bundledFonts();
} // namespace ui
