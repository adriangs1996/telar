#pragma once

#include "qt/application.hpp"
#include <QDebug>
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

  static void describe(const qt::Application &application) {
    const auto &surface = application.presented_history_surface_;
    qInfo() << "History presentation" << "delivered" << surface.delivered << "generation" << surface.generation << application.dialog_generation_ << "revision" << surface.revision << application.session().historyBrowser().revision() << "rows" << surface.has_rows << "loading" << application.historyLoading();
  }
};

}
