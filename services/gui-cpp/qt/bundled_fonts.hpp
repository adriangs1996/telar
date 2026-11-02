#pragma once

#include <QStringList>

namespace telar::gui::qt {
// Registers the fonts the GUI embeds the first time it runs.
// Returns their families in fallback order: the terminal face, then Nerd Font symbols.
const QStringList &bundledFonts();
}
