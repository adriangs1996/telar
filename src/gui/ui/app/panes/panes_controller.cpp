#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "panes_controller.hpp"
#include "pane_projection.hpp"
#include "telar_base/ds/values.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/kit/models/projection.hpp"
#include <QList>
#include <QString>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <span>
#include <utility>

namespace telar::gui::qt {

  PanesController::PanesController(Store& store, ElementSlots& elements, QObject* parent)
      : QObject(parent),
        store_(store),
        elements_(elements) {}

  QAbstractItemModel* PanesController::rows() noexcept {
    return &rows_;
  }

  QAbstractItemModel* PanesController::dividers() noexcept {
    return &dividers_;
  }

  void PanesController::resizeDivider(int index, qreal x, qreal y, bool commit) {
    try {
      if (index < 0) {
        return;
      }

      // The gesture is in the window's points; the workbench places the divider in its own pixels.
      if (application::workbench::dragDivider(store_.sessionMut(), static_cast<std::size_t>(index), x * scale_, y * scale_, commit)) {
        synchronize();
      }
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  void PanesController::setScale(double scale) noexcept {
    scale_ = scale;
  }

  void PanesController::forget() {
    rows_.reconcile({});
    dividers_.reconcile({});
    synchronized_.reset();
  }

  PanesController::Inputs PanesController::inputs() const {
    const auto& client = store_.client(store_.machines().active());
    const auto& session = client.session;
    const auto view = session.viewVersion();

    return {
        .machine_view = store_.machineView(),
        .runtime_generation = client.runtime_generation,
        .active_tab = view.active_tab,
        .panes = view.panes,
        .host = view.host,
        .configuration = view.configuration,
        .chrome = session.chromeRevision(),
        .agents = session.agentRevision(),
        .graphics = application::terminal::graphics::recoveryRevision(session),
        .elements = elements_.revision(),
        .viewport = view.viewport,
        .scale = scale_,
    };
  }

  QVariantList PanesController::fullscreenEntries(const Tab<Memory>& tab) const {
    QVariantList entries;

    if (!tab.fullscreen) {
      return entries;
    }

    const auto& session = store_.session();
    std::uint16_t index = 0;
    const auto agents = std::span<const Agent<Memory>>{session.agents()};

    forEachLeaf(tab, false, [&](const ClientLayoutPane& leaf) {
      ++index;
      entries.append(fullscreenPaneRecord(session.findPane(leaf.pane_id), agents, {.pane_id = leaf.pane_id, .index = index, .focused = tab.focused_pane == leaf.pane_id}));
    });

    return entries;
  }

  std::uint64_t PanesController::rebuilds() const noexcept {
    return rebuilds_;
  }

  void PanesController::synchronize() {
    const auto next = inputs();
    if (synchronized_ == next) {
      return;
    }

    ++rebuilds_;

    // Arranging the layout fills its placements.
    auto& session = store_.sessionMut();
    auto* tab = session.activeTabMut();
    QList<QVariantMap> panes;
    QList<QVariantMap> dividers;

    elements_.begin(ElementSlots::pane_slots);
    if (tab != nullptr) {
      const auto& geometry = application::workbench::geometry(session);
      const auto fullscreen = tab->fullscreen ? ds::Option{tab->focused_pane} : ds::none;
      const auto fullscreen_entries = fullscreenEntries(*tab);
      const auto motion_context = QStringLiteral("%1/%2/%3/%4/%5")
                                      .arg(store_.machineView())
                                      .arg(static_cast<int>(tab->location.workspace.kind))
                                      .arg(tab->location.workspace.id)
                                      .arg(tab->location.tab_id)
                                      .arg(tab->fullscreen);

      for (const auto& placement : tab->layout.arrange(geometry.cellArea(), geometry.layout_metrics, fullscreen)) {
        const auto* pane = session.findPane(placement.pane_id);
        if (pane == nullptr) {
          continue;
        }

        auto record = paneRecord(*pane, placement, geometry, tab->focused_pane == pane->id, scale_);

        // What draws the pane's content: an editor's grids, or a terminal's rows.
        record.insert(QStringLiteral("editor"), application::nvim::editor(session, pane->id) != nullptr);
        record.insert(QStringLiteral("motionContext"), motion_context);
        record.insert(QStringLiteral("fullscreen"), tab->fullscreen);
        if (tab->fullscreen) {
          record.insert(QStringLiteral("fullscreenEntries"), fullscreen_entries);
        }

        auto chrome = paneChromeRecord(*pane, std::span<const Agent<Memory>>{session.agents()}, placement.display_index, application::terminal::graphics::paused(session, pane->id));

        if (elements_.active()) {
          chrome.insert(QStringLiteral("elements"), elements_.elements(ElementSlots::pane_slots, record.value(QStringLiteral("key")).toString(), ElementSlots::paneItem(record, chrome)));
        }

        record.insert(QStringLiteral("chrome"), std::move(chrome));
        panes.append(std::move(record));
      }

      for (const auto& divider : tab->layout.dividers()) {
        const auto bounds = geometry.pixels(divider.bounds);
        QVariantMap record;

        record.insert(QStringLiteral("key"), QString::number(divider.node_index));
        record.insert(QStringLiteral("x"), static_cast<double>(bounds.x) / scale_);
        record.insert(QStringLiteral("y"), static_cast<double>(bounds.y) / scale_);
        record.insert(QStringLiteral("width"), static_cast<double>(bounds.width) / scale_);
        record.insert(QStringLiteral("height"), static_cast<double>(bounds.height) / scale_);
        record.insert(QStringLiteral("horizontal"), divider.axis == ClientLayoutAxis::horizontal);
        dividers.append(record);
      }
    }

    synchronized_ = next;
    rows_.reconcile(std::move(panes));
    dividers_.reconcile(std::move(dividers));
    elements_.finish(ElementSlots::pane_slots);
  }

}
