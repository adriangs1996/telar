#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/app/application.hpp"
#include "ui/palette/palette_controller.hpp"
#include <QByteArray>
#include <QString>
#include <cstddef>

import telar.gui.palette.navigation_label;

namespace telar::gui::qt {

  void Application::submitSuggestion(const QString& revision) {
    const auto encoded = palette_.query().toUtf8();
    const auto query = PaletteQuery::parse({encoded.constData(), static_cast<std::size_t>(encoded.size())});
    if (store_.dialog().kind != Dialog::palette || query.mode != PaletteMode::suggest || revision != palette_.suggestionRevision()) {
      return;
    }

    applyInteraction([&] {
      if (session().submitSuggestion(query.text)) {
        showDialog(Dialog::none);
      }

      palette_.publish();
    });
  }

  bool Application::restorePaletteParent() {
    if (store_.dialog().kind != Dialog::palette || !palette_.hasParent()) {
      return false;
    }

    palette_.restoreParent();
    showDialog(Dialog::palette);

    return true;
  }

}
