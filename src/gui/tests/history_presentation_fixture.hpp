#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/app/application_controller.hpp"
#include <QDebug>
#include <QPointF>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

#pragma once

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::test {

  struct HistoryPresentation {
    // Whether the dialog's ages move on, and one step of them, without waiting for the timer.
    [[nodiscard]] static bool aging(qt::ApplicationController& application) {
      return application.history()->age_timer_.isActive();
    }

    static void age(qt::ApplicationController& application) {
      application.history()->age();
    }

    static void renameTab(qt::ApplicationController& application, std::string_view label) {
      application::workbench::renameTab(application.sessionMut(), label);
    }

    [[nodiscard]] static bool current(qt::ApplicationController& application) {
      const auto& history = *application.history();
      const auto& surface = history.presented_surface_;

      return !history.loading() && surface.delivered && surface.generation == application.store_.dialog().generation && surface.revision == application::history::view(application.session()).revision();
    }

    [[nodiscard]] static ds::Option<QPointF> actionCenter(qt::ApplicationController& application, application::history::HistoryCardAction action) {
      const auto& surface = application.history()->presented_actions_;
      const auto browser = application::history::view(application.session());
      const application::history::HistoryChoice expected{.index = browser.state().selection, .revision = browser.revision()};
      if (!current(application) || surface.generation != application.store_.dialog().generation || surface.choice != expected || surface.scale <= 0) {
        return ds::none;
      }

      const auto* target = surface.find(action);
      if (target == nullptr || !target->enabled) {
        return ds::none;
      }

      return QPointF{(target->bounds.x + (target->bounds.width / 2)) / surface.scale, (target->bounds.y + (target->bounds.height / 2)) / surface.scale};
    }

    // Sets the dialog and the pane whose prompt line hosts it, then announces them, as the last two
    // steps of Dialogs::show do, so a test chooses any pane and kind in one change.
    static void showLineSearch(qt::ApplicationController& application, qt::Store::Dialog kind, std::uint64_t pane_id) {
      application.store_.setDialog(kind, pane_id);
      emit application.dialogs_.changed();
    }

    static void describe(qt::ApplicationController& application) {
      const auto& surface = application.history()->presented_surface_;

      qInfo() << "History presentation" << "delivered" << surface.delivered << "generation" << surface.generation << application.store_.dialog().generation << "revision" << surface.revision << application::history::view(application.session()).revision() << "rows" << surface.has_rows << "loading" << application.history()->loading();
    }
  };

}
