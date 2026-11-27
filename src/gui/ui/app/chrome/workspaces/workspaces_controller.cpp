#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "workspaces_controller.hpp"
#include "project_projection.hpp"
#include "telar_base/ds/values.hpp"
#include "ui/kit/models/projection.hpp"
#include <QVarLengthArray>
#include <algorithm>
#include <cstddef>
#include <numeric>
#include <span>
#include <utility>

namespace telar::gui::qt {

  namespace {

    // Workspaces of a machine whose marks are sorted without touching the heap.
    constexpr qsizetype inline_projects = 32;

  }

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
      const auto* const current = std::ranges::find_if(session.workspaces(), [&](const auto& workspace) {
        return sameWorkspace(workspace.location, active->location.workspace);
      });
      if (current != session.workspaces().end()) {
        context = workspaceRecord(*current, true, application::workbench::WorkspaceMark::resolve(current->name));
      }
    }

    const auto projects = session.workspace_list.projects();
    // The marks in the order the runtime made the workspaces, so a new one never takes an older
    // one's hue; then back in the order the track shows them.
    QVarLengthArray<std::size_t, inline_projects> made(static_cast<qsizetype>(projects.size()));
    QVarLengthArray<application::workbench::WorkspaceMark, inline_projects> marks(static_cast<qsizetype>(projects.size()));

    std::ranges::iota(made, std::size_t{0});
    std::ranges::sort(made, {}, [&](std::size_t index) {
      return projects[index].location.id;
    });

    for (qsizetype rank = 0; rank < made.size(); ++rank) {
      marks[rank] = application::workbench::WorkspaceMark::resolve(projects[made[rank]].name);
    }

    application::workbench::WorkspaceMark::distinguish(std::span{marks});

    QVarLengthArray<application::workbench::WorkspaceMark, inline_projects> shown(marks.size());

    for (qsizetype rank = 0; rank < made.size(); ++rank) {
      shown[static_cast<qsizetype>(made[rank])] = marks[rank];
    }

    for (std::size_t index = 0; index < projects.size(); ++index) {
      const auto& workspace = projects[index];
      const bool selected = selected_project == workspace.location.id;
      auto record = projectRecord(workspace, session.workspace_list, std::span<const Agent<Memory>>{session.agents()}, selected, shown[static_cast<qsizetype>(index)]);

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
