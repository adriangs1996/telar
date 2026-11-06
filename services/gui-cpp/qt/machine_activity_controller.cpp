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

  const auto command = std::get<MachineActivityTarget::Command>(target.owner);

  return prefix + QStringLiteral(":command:") + QString::number(command.worktree) + QLatin1Char(':') + QString::number(command.workspace);
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
  std::array<std::optional<ActivitySourceVersion>, Machines::capacity> versions;
  for (std::size_t index = 0; index < clients_.size(); ++index) {
    const auto &client = clients_[index];
    const auto &row = machines_.row(static_cast<Machines::Slot>(index));
    if (row.used && row.live && client) {
      versions[index] = ActivitySourceVersion{.source = (*client)->key, .runtime_generation = (*client)->runtime_generation, .agents = (*client)->session.agentRevision(), .workspaces = (*client)->session.workspaceList().revision(), .connected = row.enabled && (*client)->phase == MachinePhase::connected && (*client)->session.ready(), .label = row.label};
    }
  }

  const auto view = session().viewVersion();
  const ActivitySelection selection{.slot = machines_.active(), .tabs = view.active_tab, .panes = view.panes};
  if (versions == activity_versions_ && activity_selection_ == selection) {
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
    const AgentRecordContext context{.machine = version->label.view(), .branch = {}, .connected = version->connected, .coordinator = entry.coordinator, .starts_project = entry.first_in_project, .depth = entry.depth};
    auto record = activityRecord(source.session, entry, context, slot == machines_.active());
    record.insert(QStringLiteral("key"), identity);
    records.append(std::move(record));
    targets.push_back({.identity = identity, .target = target});
  }

  activity_targets_ = std::move(targets);
  agents_.reconcile(std::move(records));
  activity_versions_ = std::move(versions);
  activity_selection_ = selection;
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
