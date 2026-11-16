#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/app/application.hpp"
#include <QDebug>
#include <QPointF>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

#pragma once
#include "ui/app/application.hpp"

import telar.gui.history.browser;
import telar.gui.presentation.history_filter_geometry;

namespace telar::gui::test {

  struct HistoryPresentation {
    static void renameTab(qt::Application& application, std::string_view label) {
      application.session().renameTab(label);
    }

    [[nodiscard]] static bool current(qt::Application& application) {
      const auto& history = *application.history();
      const auto& surface = history.presented_surface_;

      return !history.loading() && surface.delivered && surface.generation == application.store_.dialog().generation && surface.revision == application.session().historyBrowser().revision();
    }

    [[nodiscard]] static std::optional<QPointF> actionCenter(qt::Application& application, HistoryCardAction action) {
      const auto& surface = application.history()->presented_actions_;
      const auto& browser = application.session().historyBrowser();
      const HistoryChoice expected{.index = browser.state().selection, .revision = browser.revision()};
      if (!current(application) || surface.generation != application.store_.dialog().generation || surface.choice != expected || surface.scale <= 0) {
        return std::nullopt;
      }

      const auto* target = surface.find(action);
      if (target == nullptr || !target->enabled) {
        return std::nullopt;
      }

      return QPointF{(target->bounds.x + target->bounds.width / 2) / surface.scale, (target->bounds.y + target->bounds.height / 2) / surface.scale};
    }

    static void describe(qt::Application& application) {
      const auto& surface = application.history()->presented_surface_;

      qInfo() << "History presentation" << "delivered" << surface.delivered << "generation" << surface.generation << application.store_.dialog().generation << "revision" << surface.revision << application.session().historyBrowser().revision() << "rows" << surface.has_rows << "loading" << application.history()->loading();
    }
  };

}
