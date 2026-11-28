export module telar.gui.ui.kit.models:glyph_icon;

import telar.gui.qt;
import telar.gui.foundation.icons;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  // An icon as a surface draws it: the glyph, and the role of the window's colors it takes.
  [[tbc::hot_path]] inline void putIcon(QVariantMap& record, GlyphIcon icon) {
    const auto tone = toneName(icon.tone);

    record.insert(u"icon"_s, QString::fromUcs4(&icon.glyph, 1));
    record.insert(u"iconTone"_s, QString::fromLatin1(tone.data(), static_cast<qsizetype>(tone.size())));
  }

}
