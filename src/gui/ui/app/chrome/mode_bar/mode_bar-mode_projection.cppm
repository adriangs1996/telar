export module telar.gui.ui.app.chrome.mode_bar:mode_projection;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.application;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  [[tbc::hot_path]] inline QVariantMap statusModeRecord(application::status_bar::StatusMode mode, const application::status_bar::ModeHints& hints = {}) {
    QVariantList records;

    for (const auto& hint : hints.items()) {
      records.append(QVariantMap{
          {u"key"_s, static_cast<int>(hint.key.key)},
          {u"character"_s, hint.key.character},
          {u"modifiers"_s, hint.key.modifiers},
          {u"label"_s, toQString(hint.label)},
      });
    }

    return {{u"kind"_s, static_cast<int>(mode)}, {u"hints"_s, records}};
  }

}
