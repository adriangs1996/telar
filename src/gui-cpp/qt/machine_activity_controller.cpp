#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "activity_projection.hpp"
#include "agent_projection.hpp"
#include "application.hpp"
#include "../application/dependencies.hpp"
#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <cstdint>
#include <limits>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include <string_view>
#include "machine_activity_target.hpp"
#include "machine_client.hpp"
#include <stdexcept>
#include <charconv>
#include <cstring>
#include <system_error>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <tuple>
#include <compare>
#include <QByteArray>
#include <QPointF>
#include <QQuickItem>
#include <QString>
#include <QVariantMap>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobjectdefs.h>
#include <QtCore/qtypes.h>
#include <QtCore/qtmetamacros.h>

#include "application/dependencies.hpp"
#include "core/memory.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.machines.picker;
import telar.gui.presentation.application_mark;
import telar.gui.presentation.activity_order;

namespace telar::gui::qt {

namespace {

using Order = ActivityOrder<ApplicationAllocator>;

bool containsActivityPointer(const QQuickItem &card, QPointF position) {
  if (!card.isVisible() || !card.isEnabled()) {
    return false;
  }

  for (const auto *item = &card; item != nullptr; item = item->parentItem()) {
    if ((item == &card || item->clip()) && !item->contains(item->mapFromScene(position))) {
      return false;
    }
  }

  return true;
}

MachineActivityTarget activityTarget(const MachineClient &source, const Order::Entry &entry) {
  if (entry.agent) {
    const auto &agent = source.session.agents()[*entry.agent];

    return {.source = source.key, .runtime_generation = source.runtime_generation, .owner = MachineActivityTarget::Agent{.key = {.pane_id = agent.pane_id, .pane_generation = agent.pane_generation}, .session = agent.session_id}};
  }

  if (!entry.worktree) {
    throw std::logic_error{"ActivityEntryWithoutOwner"};
  }

  const auto &row = source.session.workspaceList().worktrees()[*entry.worktree];

  return {.source = source.key, .runtime_generation = source.runtime_generation, .owner = MachineActivityTarget::Command{.worktree = row.id, .workspace = row.workspace.value_or(0)}};
}

QString activityIdentity(const MachineActivityTarget &target) {
  const auto &source = target.source;
  const auto prefix = QStringLiteral("machine:") + QString::number(source.machine.slot) + QLatin1Char(':') + QString::number(source.machine.generation) + QLatin1Char(':') + QString::number(source.generation) + QLatin1Char(':') + QString::number(target.runtime_generation);
  if (const auto *agent = std::get_if<MachineActivityTarget::Agent>(&target.owner)) {
    QByteArray session;
    session.reserve(static_cast<qsizetype>(agent->session.size()));
    for (const auto byte : agent->session) {
      session.append(static_cast<char>(byte));
    }

    return prefix + QStringLiteral(":agent:") + QString::number(agent->key.pane_id) + QLatin1Char(':') + QString::number(agent->key.pane_generation) + QLatin1Char(':') + QString::fromLatin1(session.toHex());
  }

  if (const auto *process = std::get_if<MachineActivityTarget::Process>(&target.owner)) {
    return prefix + QStringLiteral(":process:") + QString::number(process->pane_id) + QLatin1Char(':') + QString::number(process->pane_generation);
  }

  const auto command = std::get<MachineActivityTarget::Command>(target.owner);

  return prefix + QStringLiteral(":command:") + QString::number(command.worktree) + QLatin1Char(':') + QString::number(command.workspace);
}

struct ListedProcess {
  std::size_t source;
  const ListedPane *pane;
};

// Programs before idle shells; inside each, the newest foreground first. Ages sampled at different
// moments compare as `age_a - sampled_a < age_b - sampled_b`, rearranged to stay unsigned.
bool precedes(const ListedProcess &left, const ListedProcess &right) noexcept {
  if (left.pane->shell != right.pane->shell) {
    return !left.pane->shell;
  }

  const auto left_age = left.pane->age.age_ns + right.pane->age.sampled_ns;
  const auto right_age = right.pane->age.age_ns + left.pane->age.sampled_ns;
  if (left_age != right_age) {
    return left_age < right_age;
  }

  return std::tie(left.source, left.pane->pane_id) < std::tie(right.source, right.pane->pane_id);
}

std::string_view workspaceName(const GuiSession &session, const ListedPane &pane) {
  if (pane.location.workspace.kind != WorkspaceLocation::Kind::workspace) {
    return {};
  }

  const auto &workspaces = session.workspaceList().entries();
  const auto found = std::ranges::find_if(workspaces, [&](const auto &workspace) {
    return sameWorkspace(workspace.location, pane.location.workspace);
  });

  return found == workspaces.end() ? std::string_view{} : std::string_view{found->name};
}

QVariantMap activityRecord(const GuiSession &session, const Order::Entry &entry, AgentRecordContext context, bool active_source) {
  if (!entry.agent) {
    if (!entry.worktree) {
      throw std::logic_error{"ActivityEntryWithoutOwner"};
    }

    return commandRecord(session.workspaceList().worktrees()[*entry.worktree], context);
  }

  const auto &agent = session.agents()[*entry.agent];
  const auto &workspaces = session.workspaces();
  const auto workspace = std::ranges::find_if(workspaces, [&](const auto &candidate) {
    return agent.location.workspace.kind == WorkspaceLocation::Kind::workspace && sameWorkspace(agent.location.workspace, candidate.location);
  });
  context.branch = workspace == workspaces.end() ? std::string_view{} : std::string_view{workspace->branch};
  const auto *tab = active_source ? session.activeTab() : nullptr;
  context.selected = tab != nullptr && agent.pane_id == tab->focused_pane && sameTab(agent.location, tab->location);
  if (entry.worktree) {
    return taskRecord(agent, session.workspaceList().worktrees()[*entry.worktree], context, entry.card == ActivityCard::task_compact);
  }

  return agentRecord(agent, context);
}

}

void Application::refreshAgents() {
  // The top bar names the active machine, so only cards from other machines repeat theirs.
  const auto machineLabel = [this](const ActivitySourceVersion &version, Machines::Slot slot) {
    return slot == machines_.active() ? std::string_view{} : version.label.view();
  };
  std::array<std::optional<ActivitySourceVersion>, Machines::capacity> versions;
  for (std::size_t index = 0; index < clients_.size(); ++index) {
    const auto &client = clients_[index];
    const auto &row = machines_.row(static_cast<Machines::Slot>(index));
    if (row.used && row.live && client) {
      versions[index] = ActivitySourceVersion{.source = (*client)->key, .runtime_generation = (*client)->runtime_generation, .agents = (*client)->session.agentRevision(), .workspaces = (*client)->session.workspaceList().revision(), .panes = (*client)->session.paneListRevision(), .connected = row.enabled && (*client)->phase == MachinePhase::connected && (*client)->session.ready(), .label = row.label};
    }
  }

  const auto view = session().viewVersion();
  const ActivitySelection selection{.slot = machines_.active(), .tabs = view.active_tab, .panes = view.panes};
  if (versions == activity_versions_ && activity_selection_ == selection) {
    // The cards stay as they are, and so do the mod instances drawing them.
    element_slots_.retain({components::Slot::agent_card, components::Slot::agent_mark, components::Slot::agent_title, components::Slot::agent_project, components::Slot::agent_status});
    return;
  }

  Vector<Order::Source, ApplicationAllocator> sources{AllocatorRef<Order::Source, ApplicationAllocator>{memory_}};
  sources.reserve(Machines::capacity);
  for (std::size_t index = 0; index < versions.size(); ++index) {
    if (!versions[index]) {
      continue;
    }

    const auto slot = static_cast<Machines::Slot>(index);
    const auto &session = clientAt(slot).session;
    const auto *tab = session.activeTab();
    sources.push_back({.slot = slot, .agents = session.agents(), .workspaces = session.workspaceList(), .focused = tab == nullptr ? std::nullopt : std::optional{tab->focused_pane}});
  }

  Order::Plan order;
  Order::write(sources, machines_.active(), order);
  QList<QVariantMap> records;
  records.reserve(static_cast<qsizetype>(order.count));
  Vector<ActivityRowTarget, ApplicationAllocator> targets{AllocatorRef<ActivityRowTarget, ApplicationAllocator>{memory_}};
  targets.reserve(order.count);
  for (const auto &entry : order.view()) {
    const auto slot = sources[entry.source].slot;
    const auto &source = clientAt(slot);
    const auto &version = versions[slot];
    if (!version) {
      throw std::logic_error{"ActivitySourceWithoutVersion"};
    }

    const auto target = activityTarget(source, entry);
    const auto identity = activityIdentity(target);
    const AgentRecordContext context{.machine = machineLabel(*version, slot), .branch = {}, .connected = version->connected, .coordinator = entry.coordinator, .starts_project = entry.first_in_project, .depth = entry.depth};
    auto record = activityRecord(source.session, entry, context, slot == machines_.active());
    record.insert(QStringLiteral("key"), identity);
    if (element_slots_.active()) {
      record.insert(QStringLiteral("elements"), elementsFor({components::Slot::agent_card, components::Slot::agent_mark, components::Slot::agent_title, components::Slot::agent_project, components::Slot::agent_status}, identity, ElementSlots::agentItem(record)));
    }

    records.append(std::move(record));
    targets.push_back({.identity = identity, .target = target});
  }

  const auto agent_count = static_cast<int>(records.size());
  Vector<ListedProcess, ApplicationAllocator> processes{AllocatorRef<ListedProcess, ApplicationAllocator>{memory_}};
  // Processes are the active machine's; the other machines are summarized by their sidebar row.
  for (std::size_t index = 0; index < sources.size(); ++index) {
    if (sources[index].slot != machines_.active()) {
      continue;
    }

    const auto &session = clientAt(sources[index].slot).session;
    for (const auto &pane : session.paneList()) {
      const auto held = std::ranges::any_of(session.agents(), [&](const auto &agent) {
        return agent.pane_id == pane.pane_id && agent.pane_generation == pane.pane_generation;
      });
      if (!held) {
        processes.push_back({.source = index, .pane = &pane});
      }
    }
  }

  std::ranges::sort(processes, precedes);
  if (!processes.empty()) {
    records.append(processHeaderRecord(static_cast<qsizetype>(processes.size())));
  }

  records.reserve(records.size() + static_cast<qsizetype>(processes.size()));
  targets.reserve(targets.size() + processes.size());
  for (const auto &process : processes) {
    const auto slot = sources[process.source].slot;
    const auto &source = clientAt(slot);
    const auto &version = *versions[slot];
    const auto &pane = *process.pane;
    const MachineActivityTarget target{.source = source.key, .runtime_generation = source.runtime_generation, .owner = MachineActivityTarget::Process{.pane_id = pane.pane_id, .pane_generation = pane.pane_generation}};
    const auto identity = activityIdentity(target);
    const auto *tab = slot == machines_.active() ? source.session.activeTab() : nullptr;
    const AgentRecordContext context{.machine = machineLabel(version, slot), .selected = tab != nullptr && pane.pane_id == tab->focused_pane && sameTab(pane.location, tab->location), .connected = version.connected};
    auto record = processRecord(pane, workspaceName(source.session, pane), context);
    record.insert(QStringLiteral("key"), identity);
    records.append(std::move(record));
    targets.push_back({.identity = identity, .target = target});
  }

  activity_targets_ = std::move(targets);
  agents_.reconcile(std::move(records));
  fitSidebarWhenReady();
  activity_versions_ = std::move(versions);
  activity_selection_ = selection;
  if (activity_agent_count_ != agent_count) {
    activity_agent_count_ = agent_count;
    emit activityCountChanged();
  }
}

int Application::activityAgentCount() const noexcept {
  return activity_agent_count_;
}

bool Application::activityAvailable(const MachineActivityTarget &target) const {
  const auto *client = findClient(target.source);
  if (client == nullptr || client->runtime_generation != target.runtime_generation || !machines_.shown(target.source.machine.slot) || !machines_.row(target.source.machine.slot).live || !machines_.row(target.source.machine.slot).enabled || client->phase != MachinePhase::connected || !client->session.ready()) {
    return false;
  }

  if (const auto *agent = std::get_if<MachineActivityTarget::Agent>(&target.owner)) {
    return std::ranges::any_of(client->session.agents(), [&](const auto &candidate) {
      return candidate.pane_id == agent->key.pane_id && candidate.pane_generation == agent->key.pane_generation && candidate.session_id == agent->session;
    });
  }

  if (const auto *process = std::get_if<MachineActivityTarget::Process>(&target.owner)) {
    return std::ranges::any_of(client->session.paneList(), [&](const auto &pane) {
      return pane.pane_id == process->pane_id && pane.pane_generation == process->pane_generation;
    });
  }

  const auto command = std::get<MachineActivityTarget::Command>(target.owner);
  const auto *row = client->session.workspaceList().worktree(command.worktree);

  return row != nullptr && row->workspace && *row->workspace == command.workspace;
}

void Application::selectActivity(const QString &identity, bool peek) {
  pending_activity_.reset();
  const auto row = std::ranges::find(activity_targets_, identity, &ActivityRowTarget::identity);
  if (row == activity_targets_.end() || !activityAvailable(row->target) || (peek && !std::holds_alternative<MachineActivityTarget::Agent>(row->target.owner))) {
    return;
  }

  const auto target = row->target;
  selectMachine(target.source.machine);
  hoverActivity(identity);
  pending_activity_ = PendingActivity{.target = target, .window = window_generation_, .peek = peek, .pointer_revision = pointer_revision_};
  settleActivity();
}

void Application::settleActivity() {
  if (!pending_activity_) {
    return;
  }

  const auto pending = *pending_activity_;
  if (pending.window != window_generation_ || pending.target.source.machine.slot != machines_.active() || !activityAvailable(pending.target)) {
    pending_activity_.reset();

    return;
  }

  if (session().requestsPending()) {
    return;
  }

  pending_activity_.reset();
  if (const auto *agent = std::get_if<MachineActivityTarget::Agent>(&pending.target.owner)) {
    if (pending.peek) {
      openActivityPeek(pending.target, activityIdentity(pending.target), pending.pointer_revision);
    } else {
      static_cast<void>(session().focusAgent(agent->key.pane_id, agent->key.pane_generation));
    }
  } else if (const auto *process = std::get_if<MachineActivityTarget::Process>(&pending.target.owner)) {
    static_cast<void>(session().focusListedPane(process->pane_id, process->pane_generation));
  } else {
    static_cast<void>(session().openWorktree(std::get<MachineActivityTarget::Command>(pending.target.owner).worktree));
  }
}

QString Application::activityHover() const {
  return activity_hover_;
}

void Application::hoverActivity(const QString &identity, QQuickItem *card) {
  const auto owned_exit = identity.isEmpty() && card != nullptr && activity_hover_card_ == card;
  if (!activity_hover_pending_ && !owned_exit) {
    return;
  }

  if (identity.isEmpty()) {
    if (card != nullptr && activity_hover_card_ != card) {
      return;
    }

    activity_hover_card_.clear();
  } else {
    if (card != nullptr && (card->window() != window_ || !activity_pointer_position_ || !containsActivityPointer(*card, *activity_pointer_position_))) {
      return;
    }

    const auto row = std::ranges::find(activity_targets_, identity, &ActivityRowTarget::identity);
    if (row == activity_targets_.end() || !activityAvailable(row->target)) {
      return;
    }

    if (card != nullptr) {
      if (activity_hover_card_ != card) {
        activity_hover_card_ = card;
      }
    } else if (activity_hover_ != identity) {
      activity_hover_card_.clear();
    }
  }

  activity_hover_seen_ = true;
  if (activity_hover_ != identity) {
    activity_hover_ = identity;
    emit activityHoverChanged();
  }
}

void Application::clearActivityHover() {
  activity_hover_card_.clear();

  if (activity_hover_.isEmpty()) {
    return;
  }

  activity_hover_.clear();
  emit activityHoverChanged();
}

void Application::observeActivityPointer(bool hover_input, std::optional<QPointF> position) {
  ++pointer_revision_;
  activity_pointer_position_ = position;
  activity_hover_pending_ = hover_input;
  activity_hover_seen_ = false;
  if (!hover_input) {
    clearActivityHover();

    return;
  }

  if (activity_hover_reset_queued_) {
    return;
  }

  activity_hover_reset_queued_ = true;
  QMetaObject::invokeMethod(this, [this] {
    activity_hover_pending_ = false;
    activity_hover_reset_queued_ = false;
    if (!activity_hover_seen_) {
      clearActivityHover();
    }
  },
                            Qt::QueuedConnection);
}

}
