#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "workspaces_controller.hpp"
#include "project_projection.hpp"
#include "ui/foundation/models/projection.hpp"
#include "telar_base/ds/values.hpp"
#include <algorithm>
#include <span>
#include <utility>

namespace telar::gui::qt {

  WorkspacesController::WorkspacesController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {}

  QAbstractItemModel* WorkspacesController::rows() noexcept {
    return &rows_;
  }

  int WorkspacesController::count() const noexcept {
    return rows_.rowCount();
  }

  const QVariantMap& WorkspacesController::context() const noexcept {
    return context_;
  }

  void WorkspacesController::forget() {
    rows_.reconcile({});
    synchronized_.reset();
  }

  WorkspacesController::Inputs WorkspacesController::inputs() const {
    const auto& client = store_.client(store_.machines().active());
    const auto& session = client.session;
    const auto view = session.viewVersion();

    return {
        .machine_view = store_.machineView(),
        .runtime_generation = client.runtime_generation,
        .workspace = view.workspace,
        .active_tab = view.active_tab,
        .workspace_list = session.workspace_list.revision(),
        .agents = session.agentRevision(),
    };
  }

  std::uint64_t WorkspacesController::rebuilds() const noexcept {
    return rebuilds_;
  }

  void WorkspacesController::synchronize() {
    const auto next = inputs();
    if (synchronized_ == next) {
      return;
    }

    ++rebuilds_;

    const auto& session = store_.session();
    const auto* active = session.activeTab();
    QList<QVariantMap> workspaces;
    QVariantMap context;
    ds::Option<std::uint64_t> selected_project;

    if (active != nullptr && active->location.workspace.kind == WorkspaceLocation::Kind::workspace) {
      selected_project = session.workspace_list.projectOf(active->location.workspace.id);
      const auto current = std::ranges::find_if(session.workspaces(), [&](const auto& workspace) {
        return sameWorkspace(workspace.location, active->location.workspace);
      });
      if (current != session.workspaces().end()) {
        context = workspaceRecord(*current, true);
      }
    }

    for (const auto& workspace : session.workspace_list.projects()) {
      const bool selected = selected_project == workspace.location.id;
      auto record = projectRecord(workspace, session.workspace_list, std::span<const Agent<Memory>>{session.agents()}, selected);

      record.insert(QStringLiteral("index"), workspaces.size());
      if (selected) {
        context.insert(QStringLiteral("index"), workspaces.size());
      }

      workspaces.append(std::move(record));
    }

    synchronized_ = next;
    rows_.reconcile(std::move(workspaces));
    if (context_ != context) {
      context_ = std::move(context);
      emit contextChanged();
    }
  }

}
