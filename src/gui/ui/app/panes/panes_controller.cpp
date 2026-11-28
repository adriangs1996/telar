module telar.gui.ui.app.panes;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

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
      const application::workbench::DividerDrag drag{.node = static_cast<std::size_t>(index), .x = x * scale_, .y = y * scale_, .commit = commit};
      if (application::workbench::dragDivider(store_.sessionMut(), drag)) {
        synchronize();
      }
    } catch (const std::exception& error) {
      failed(QString::fromUtf8(error.what()));
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
      const auto motion_context = u"%1/%2/%3/%4/%5"_s
                                      .arg(store_.machineView())
                                      .arg(static_cast<int>(tab->location.workspace.kind))
                                      .arg(tab->location.workspace.id)
                                      .arg(tab->location.tab_id)
                                      .arg(tab->fullscreen);

      std::size_t leaves = 0;

      forEachLeaf(*tab, false, [&]([[maybe_unused]] const ClientLayoutPane& leaf) {
        ++leaves;
      });

      for (const auto& placement : tab->layout.arrange(geometry.cellArea(), geometry.layout_metrics, fullscreen)) {
        const auto* pane = session.findPane(placement.pane_id);
        if (pane == nullptr) {
          continue;
        }

        auto record = paneRecord(*pane, placement, geometry, tab->focused_pane == pane->id, scale_);

        // What draws the pane's content: an editor's grids, or a terminal's rows.
        record.insert(u"editor"_s, application::nvim::editor(session, pane->id) != nullptr);
        // The explorer draws itself in the room of the pane it stands as.
        record.insert(u"explorer"_s, application::explorer::docked(session.explorer, pane->id) != nullptr);
        record.insert(u"motionContext"_s, motion_context);
        record.insert(u"fullscreen"_s, tab->fullscreen);
        if (tab->fullscreen) {
          record.insert(u"fullscreenEntries"_s, fullscreen_entries);
        }

        auto chrome = paneChromeRecord(*pane, std::span<const Agent<Memory>>{session.agents()}, placement.display_index, application::terminal::graphics::paused(session, pane->id));

        // A tab's only pane works where the tab says: its header does not repeat the directory.
        chrome.insert(u"aloneInTab"_s, leaves == 1);
        if (elements_.active()) {
          chrome.insert(u"elements"_s, elements_.elements(ElementSlots::pane_slots, record.value(u"key"_s).toString(), ElementSlots::paneItem(record, chrome)));
        }

        record.insert(u"chrome"_s, std::move(chrome));
        panes.append(std::move(record));
      }

      for (const auto& divider : tab->layout.dividers()) {
        const auto bounds = geometry.pixels(divider.bounds);
        QVariantMap record;

        record.insert(u"key"_s, QString::number(divider.node_index));
        record.insert(u"x"_s, static_cast<double>(bounds.x) / scale_);
        record.insert(u"y"_s, static_cast<double>(bounds.y) / scale_);
        record.insert(u"width"_s, static_cast<double>(bounds.width) / scale_);
        record.insert(u"height"_s, static_cast<double>(bounds.height) / scale_);
        record.insert(u"horizontal"_s, divider.axis == ClientLayoutAxis::horizontal);
        dividers.append(record);
      }
    }

    synchronized_ = next;
    rows_.reconcile(std::move(panes));
    dividers_.reconcile(std::move(dividers));
    elements_.finish(ElementSlots::pane_slots);
  }

}
