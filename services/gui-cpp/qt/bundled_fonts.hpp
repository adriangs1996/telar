#pragma once

#include <QStringList>

namespace telar::gui::qt {
// Registers the fonts the GUI embeds the first time it runs.
// Returns Telar Forma, JetBrains Mono and Nerd Font symbols in fallback order.
const QStringList &bundledFonts();
}
