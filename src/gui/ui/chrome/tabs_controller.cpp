#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "tabs_controller.hpp"
#include "ui/app/projection.hpp"
#include <QList>
#include <algorithm>
#include <span>
#include <utility>


namespace telar::gui::qt {

  TabsController::TabsController(Store& store, ElementSlots& elements, QObject* parent)
      : QObject(parent),
        store_(store),
        elements_(elements) {}

  QAbstractItemModel* TabsController::rows() noexcept {
    return &rows_;
  }

  int TabsController::count() const noexcept {
    return rows_.rowCount();
  }

  void TabsController::forget() {
    rows_.reconcile({});
    synchronized_.reset();
  }

  TabsController::Inputs TabsController::inputs() const {
    const auto& client = store_.client(store_.machines().active());
    const auto& session = client.session;
    const auto view = session.viewVersion();

    return {
        .machine_view = store_.machineView(),
        .runtime_generation = client.runtime_generation,
        .tabs = view.tabs,
        .active_tab = view.active_tab,
        .panes = view.panes,
        .configuration = view.configuration,
        .chrome = session.chromeRevision(),
        .agents = session.agentRevision(),
        .elements = elements_.revision(),
    };
  }

  void TabsController::synchronize() {
    const auto next = inputs();
    if (synchronized_ == next) {
      return;
    }

    const auto& session = store_.session();
    const auto* active = session.activeTab();
    QList<const Tab<Memory>*> ordered;

    for (const auto& tab : session.tabs()) {
      if (active != nullptr && sameWorkspace(tab->location.workspace, active->location.workspace)) {
        ordered.append(tab.get());
      }
    }

    std::ranges::stable_sort(ordered, [](const auto* left, const auto* right) {
      return left->position < right->position;
    });

    QList<QVariantMap> tabs;

    elements_.begin(ElementSlots::tab_slots);
    for (const auto* tab : ordered) {
      const auto* pane = session.findPane(tab->focused_pane);
      auto record = tabRecord(*tab, pane, session.panes(), std::span<const Agent<Memory>>{session.agents()}, tab == active);

      if (elements_.active()) {
        record.insert(QStringLiteral("elements"), elements_.elements(ElementSlots::tab_slots, record.value(QStringLiteral("key")).toString(), ElementSlots::tabItem(record, static_cast<int>(tabs.size()))));
      }

      tabs.append(std::move(record));
    }

    synchronized_ = next;
    rows_.reconcile(std::move(tabs));
    elements_.finish(ElementSlots::tab_slots);
  }

}
