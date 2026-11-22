#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QString>
#include <QVariantMap>

#pragma once

import telar.gui.foundation.icons;

namespace telar::gui::qt {

  // An icon as a surface draws it: the glyph, and the role of the window's colors it takes.
  inline void putIcon(QVariantMap& record, GlyphIcon icon) {
    const auto tone = toneName(icon.tone);

    record.insert(QStringLiteral("icon"), QString::fromUcs4(&icon.glyph, 1));
    record.insert(QStringLiteral("iconTone"), QString::fromLatin1(tone.data(), static_cast<qsizetype>(tone.size())));
  }

}
