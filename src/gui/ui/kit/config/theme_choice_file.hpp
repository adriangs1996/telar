#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QByteArray>
#include <QString>

#pragma once

import telar.gui.application;
import telar.gui.foundation.system;
import telar.base.ds;

namespace telar::gui::qt {

  // The file every window keeps the theme picker's choice in, `$XDG_STATE_HOME/telar/theme`:
  // private to its owner, replaced whole, and polled by its stamp so each window follows it.
  class ThemeChoiceFile {
  public:
    using Choice = application::configuration::ThemeChoice;

    // No path keeps no choice: reads find none and writes do nothing.
    void open(const QString& path);

    // The choice the file holds now, or none when it holds none or something unreadable.
    [[nodiscard]] ds::Option<Choice> read();

    // Whether the file changed since the last read or write.
    [[nodiscard]] bool changed() const;

    // Throws when the file cannot be replaced or removed.
    void write(const Choice& choice);
    void remove();

    [[nodiscard]] bool enabled() const noexcept;

  private:
    [[nodiscard]] ds::Option<system::PrivateFileStamp> stamp() const;

    QByteArray path_;
    ds::Option<system::PrivateFileStamp> stamp_;
  };

}
