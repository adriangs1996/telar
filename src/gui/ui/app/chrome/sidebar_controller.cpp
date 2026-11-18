#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "sidebar_controller.hpp"
#include "sidebar_projection.hpp"
#include "ui/foundation/fonts/resident_fonts.hpp"
#include "ui/foundation/fonts/typography_projection.hpp"
#include "ui/foundation/fonts/window_font_catalog.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QAbstractItemModel>
#include <QString>
#include <QtCore/qstringliteral.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <string_view>

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  SidebarController::SidebarController(Store& store, WorkspacesController& workspaces, ActivityController& activity, QObject* parent)
      : QObject(parent),
        store_(store),
        workspaces_(workspaces),
        activity_(activity) {
    // The regions make room for every workspace the list holds.
    connect(workspaces_.rows(), &QAbstractItemModel::rowsInserted, this, &SidebarController::changed);
    connect(workspaces_.rows(), &QAbstractItemModel::rowsRemoved, this, &SidebarController::changed);
    connect(workspaces_.rows(), &QAbstractItemModel::rowsMoved, this, &SidebarController::changed);
    connect(workspaces_.rows(), &QAbstractItemModel::dataChanged, this, &SidebarController::changed);
  }

  void SidebarController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    emit changed();
  }

  void SidebarController::setWindow(QQuickWindow& window) {
    window_ = &window;
  }

  bool SidebarController::machineListCollapsed() const noexcept {
    return machine_list_collapsed_;
  }

  int SidebarController::machineCount() const noexcept {
    return static_cast<int>(store_.machines().count());
  }

  application::SidebarMachines SidebarController::machines() const noexcept {
    const auto count = store_.machines().count();

    return {.shown = count > 1, .rows = count > 1 && !machine_list_collapsed_ ? count - 1 : 0};
  }

  void SidebarController::publishMachines() {
    const auto machines = this->machines();
    if (machines != machines_) {
      machines_ = machines;
      emit changed();
    }

    emit machinesChanged();
  }

  void SidebarController::toggleMachineList() {
    machine_list_collapsed_ = !machine_list_collapsed_;
    machines_ = machines();
    emit changed();
  }

  QVariantMap SidebarController::regions() const {
    const auto& geometry = display_.geometry;

    const Rect area{
        .width = geometry.sidebar.width,
        .height = geometry.sidebar.height,
    };

    auto result = sidebarRegionsRecord(area, display_, static_cast<std::size_t>(workspaces_.count()), machines());

    result.insert(QStringLiteral("typography"), chromeTypographyRecord(display_, store_.session().configuration().font));

    return result;
  }

  void SidebarController::refit() {
    fit_pending_ = true;
    fitWhenReady();
  }

  void SidebarController::fitWhenReady() {
    if (!store_.session().configuration().sidebar_width_auto) {
      fit_pending_ = false;
      return;
    }

    const auto& client = store_.clients()[store_.machines().active()];
    if (!fit_pending_ || window_ == nullptr || !client || !(*client)->session.ready()) {
      return;
    }

    fit_pending_ = false;
    fit();
  }

  void SidebarController::fit() {
    if (window_ != nullptr) {
      emit widthRequested(naturalWidth());
    }
  }

  // The logical width that shows the longest card and machine row whole, at most a third of
  // the window. The cards are measured from their records, so the ones scrolled out count too.
  float SidebarController::naturalWidth() const {
    const auto& display = display_;
    const auto& chrome = display.chrome;
    auto& catalog = WindowFontCatalog::forWindow(*window_);
    const auto fonts = ResidentFonts::shared(catalog.collection());
    const auto measure = [&](const QString& text, auto pixels, bool emphasized) {
      if (text.isEmpty()) {
        return 0.0F;
      }

      const auto utf8 = text.toUtf8();
      const std::string_view view{utf8.constData(), static_cast<std::size_t>(utf8.size())};
      const auto role = emphasized ? fonts::FontRole::emphasized : fonts::FontRole::regular;

      catalog.request(view, role);

      return static_cast<float>(fonts::TextLayout<ConcurrentMemory>::measure(*fonts, view, {.pixel_height = pixels, .preferred = role}));
    };

    const auto card = application::activity::AgentCardGeometry::derive(chrome);
    const auto padding = 2 * card.px(application::activity::AgentCardGeometry::horizontal_padding);
    const auto gap = card.px(application::activity::AgentCardGeometry::gap);
    const auto mark = card.px(application::activity::AgentCardGeometry::mark_column);
    // A status whose clock is drawn later reserves a short age.
    const auto age = QStringLiteral("59m");
    float card_width = 0;

    const auto& cards = activity_.records();

    for (int row = 0; row < cards.rowCount(); ++row) {
      const auto record = cards.data(cards.index(row), ListModel::record_role).toMap();
      const auto ports = record.value(QStringLiteral("ports")).toString();
      const auto status = record.value(QStringLiteral("status")).toString();
      const auto title = padding + mark + gap + measure(record.value(QStringLiteral("title")).toString(), chrome.body, true) + (ports.isEmpty() ? 0 : gap + measure(ports, chrome.small, false) + padding) + gap + measure(status.isEmpty() ? age : status, chrome.small, false);
      const auto detail = padding + mark + gap + measure(record.value(QStringLiteral("project")).toString(), chrome.small, false);

      card_width = std::max({card_width, title, detail});
    }

    float machines_width = 0;

    for (std::size_t index = 0; index < store_.clients().size() && !machine_list_collapsed_; ++index) {
      const auto slot = static_cast<application::machines::Machines::Slot>(index);
      if (slot == store_.machines().active() || !store_.machines().shown(slot)) {
        continue;
      }

      const auto& client = store_.clients()[index];
      const auto& row = store_.machines().row(slot);
      std::size_t active = 0;

      if (client) {
        active = static_cast<std::size_t>(std::ranges::count_if((*client)->session.agents(), [](const auto& agent) {
          return application::activity::AgentOrder::stacked(agent.status);
        }));
      }

      ds::Array<char, application::machines::MachineChromeGeometry::list_status_capacity> storage{};
      const auto status = application::machines::MachineChromeGeometry::listStatus(row.live, active, storage.viewMut());
      const auto advance = std::max(measure(toQString(row.label.view()), chrome.body, true), measure(toQString(status), chrome.small, false));

      machines_width = std::max(machines_width, application::machines::MachineChromeGeometry::listNaturalWidth(chrome, advance, active != 0));
    }

    const auto scale = display.viewport.scale;
    const auto content = std::max(card.listWidth(card_width), machines_width) + (2 * std::round(chrome.textPx(application::SidebarGeometry::margin)));
    const auto third = static_cast<float>(display.viewport.width) / scale / 3;

    return std::clamp(std::ceil(content / scale), Configuration::minimum_sidebar_width, std::max(Configuration::minimum_sidebar_width, third));
  }

}
