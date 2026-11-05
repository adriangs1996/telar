#pragma once

#include "history/choice.hpp"
#include "presentation/history_actions.hpp"
#include "qt/application.hpp"
#include <QDebug>
#include <QPointF>
#include <optional>
#include <string_view>

namespace telar::gui::test {

struct HistoryPresentation {
  static void renameTab(qt::Application &application, std::string_view label) {
    application.session().renameTab(label);
  }

  [[nodiscard]] static bool current(const qt::Application &application) {
    const auto &surface = application.presented_history_surface_;

    return !application.historyLoading() && surface.delivered && surface.generation == application.dialog_generation_ && surface.revision == application.session().historyBrowser().revision();
  }

  [[nodiscard]] static std::optional<QPointF> actionCenter(const qt::Application &application, HistoryCardAction action) {
    const auto &surface = application.presented_history_actions_;
    const auto &browser = application.session().historyBrowser();
    const HistoryChoice expected{.index = browser.state().selection, .revision = browser.revision()};
    if (!current(application) || surface.generation != application.dialog_generation_ || surface.choice != expected || surface.scale <= 0) {
      return std::nullopt;
    }

    const auto *target = surface.find(action);
    if (target == nullptr || !target->enabled) {
      return std::nullopt;
    }

    return QPointF{(target->bounds.x + target->bounds.width / 2) / surface.scale, (target->bounds.y + target->bounds.height / 2) / surface.scale};
  }

  static void describe(const qt::Application &application) {
    const auto &surface = application.presented_history_surface_;
    qInfo() << "History presentation" << "delivered" << surface.delivered << "generation" << surface.generation << application.dialog_generation_ << "revision" << surface.revision << application.session().historyBrowser().revision() << "rows" << surface.has_rows << "loading" << application.historyLoading();
  }
};

}
