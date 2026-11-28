export module telar.gui.ui.kit.fonts:typography_projection;

import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.foundation.core;
import telar.gui.application;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  [[tbc::hot_path]] inline QVariantMap chromeTypographyRecord(const application::window::DisplayMetrics& display, const FontConfiguration& font) {
    const auto& chrome = display.chrome;
    const auto density = display.density;

    return {
        {u"body"_s, chrome.body / density},
        {u"small"_s, chrome.small / density},
        {u"title"_s, chrome.title / density},
        {u"bodyRow"_s, static_cast<double>(ChromeMetrics::lineHeight(chrome.body)) / density},
        {u"smallRow"_s, static_cast<double>(ChromeMetrics::lineHeight(chrome.small)) / density},
        {u"primaryFamily"_s, toQString(font.family.view())},
        {u"primaryStyle"_s, toQString(font.style.view())},
    };
  }

}
