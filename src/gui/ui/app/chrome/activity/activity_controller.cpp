#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "activity_controller.hpp"
#include "activity_projection.hpp"
#include "agent_projection.hpp"
#include "ui/kit/machines/machine_client.hpp"
#include "ui/kit/models/activity_availability.hpp"
#include <QByteArray>
#include <QList>
#include <QMetaObject>
#include <QVariantMap>
#include <algorithm>
#include <ranges>
#include <span>
#include <stdexcept>
#include <string_view>
#include <tuple>
#include <utility>
#include <variant>

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  namespace {

    using Order = application::activity::ActivityOrder<Memory>;

    bool containsActivityPointer(const QQuickItem& card, QPointF position) {
      if (!card.isVisible() || !card.isEnabled()) {
        return false;
      }

      for (const auto* item = &card; item != nullptr; item = item->parentItem()) {
        if ((item == &card || item->clip()) && !item->contains(item->mapFromScene(position))) {
          return false;
        }
      }

      return true;
    }

    application::machines::MachineActivityTarget activityTarget(const MachineClient& source, const Order::Entry& entry) {
      if (entry.agent) {
        const auto& agent = source.session.agents()[*entry.agent];

        return {.source = source.key, .runtime_generation = source.runtime_generation, .owner = application::machines::MachineActivityTarget::Agent{.key = {.pane_id = agent.pane_id, .pane_generation = agent.pane_generation}, .session = agent.session_id}};
      }

      if (!entry.worktree) {
        throw std::logic_error{"ActivityEntryWithoutOwner"};
      }

      const auto& row = source.session.workspace_list.worktrees()[*entry.worktree];

      return {.source = source.key, .runtime_generation = source.runtime_generation, .owner = application::machines::MachineActivityTarget::Command{.worktree = row.id, .workspace = row.workspace.valueOr(0)}};
    }

    struct ListedProcess {
      std::size_t source;
      const ListedPane* pane;
    };

    // Programs before idle shells; inside each, the newest foreground first. Ages sampled at different
    // moments compare as `age_a - sampled_a < age_b - sampled_b`, rearranged to stay unsigned.
    bool precedes(const ListedProcess& left, const ListedProcess& right) noexcept {
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

    tbc::val_a<std::string_view> workspaceName(tbc::ref_a<GuiSession> session, const ListedPane& pane) {
      if (pane.location.workspace.kind != WorkspaceLocation::Kind::workspace) {
        return {};
      }

      const auto& workspaces = session.workspace_list.entries();
      const auto* const found = std::ranges::find_if(workspaces, [&](const auto& workspace) {
        return sameWorkspace(workspace.location, pane.location.workspace);
      });

      return found == workspaces.end() ? std::string_view{} : std::string_view{found->name};
    }

    QVariantMap activityRecord(const GuiSession& session, const Order::Entry& entry, AgentRecordContext context, bool active_source) {
      if (!entry.agent) {
        if (!entry.worktree) {
          throw std::logic_error{"ActivityEntryWithoutOwner"};
        }

        return commandRecord(session.workspace_list.worktrees()[*entry.worktree], context);
      }

      const auto& agent = session.agents()[*entry.agent];
      const auto& workspaces = session.workspaces();
      const auto* const workspace = std::ranges::find_if(workspaces, [&](const auto& candidate) {
        return agent.location.workspace.kind == WorkspaceLocation::Kind::workspace && sameWorkspace(agent.location.workspace, candidate.location);
      });

      context.branch = workspace == workspaces.end() ? std::string_view{} : std::string_view{workspace->branch};
      const auto* tab = active_source ? session.activeTab() : nullptr;

      context.selected = tab != nullptr && agent.pane_id == tab->focused_pane && sameTab(agent.location, tab->location);
      if (entry.worktree) {
        return taskRecord(agent, session.workspace_list.worktrees()[*entry.worktree], context);
      }

      return agentRecord(agent, context);
    }

    // The active machine's panes that no agent holds; the other machines are summarized by their
    // sidebar row.
    void listProcesses(tbc::ref_a<Store> store, std::span<const Order::Source> sources, application::machines::Machines::Slot active, tbc::holds<ds::Vec<ListedProcess, ApplicationAllocator>&, tbc::lt::a> processes) {
      for (std::size_t index = 0; index < sources.size(); ++index) {
        if (sources[index].slot != active) {
          continue;
        }

        const auto& session = store.client(sources[index].slot).session;

        for (const auto& pane : session.paneList()) {
          const auto held = std::ranges::any_of(session.agents(), [&](const auto& agent) {
            return agent.pane_id == pane.pane_id && agent.pane_generation == pane.pane_generation;
          });
          if (!held) {
            processes.push({.source = index, .pane = &pane});
          }
        }
      }

      std::ranges::sort(processes.viewMut(), precedes);
    }

    // The row's key, and the mod content its slots draw.
    void keyAgentRecord(QVariantMap& record, const QString& key, ElementSlots& elements) {
      record.insert(QStringLiteral("key"), key);
      if (elements.active()) {
        record.insert(QStringLiteral("elements"), elements.elements(ElementSlots::agent_slots, key, ElementSlots::agentItem(record)));
      }
    }

    QVariantMap processRow(const GuiSession& session, const ListedPane& pane, AgentRecordContext context, bool active_source, const QString& key) {
      const auto* tab = active_source ? session.activeTab() : nullptr;

      context.selected = tab != nullptr && pane.pane_id == tab->focused_pane && sameTab(pane.location, tab->location);
      auto record = processRecord(pane, workspaceName(session, pane), context);

      record.insert(QStringLiteral("key"), key);

      return record;
    }

  }

  ActivityController::ActivityController(Store& store, ElementSlots& elements, ApplicationAllocator& memory, QObject* parent)
      : QObject(parent),
        store_(store),
        elements_(elements),
        memory_(memory),
        targets_(memory) {}

  QAbstractItemModel* ActivityController::rows() noexcept {
    return &rows_;
  }

  const ListModel& ActivityController::records() const noexcept {
    return rows_;
  }

  int ActivityController::agentCount() const noexcept {
    return agent_count_;
  }

  std::uint64_t ActivityController::rebuilds() const noexcept {
    return rebuilds_;
  }

  void ActivityController::forget() {
    rows_.reconcile({});
    selection_.reset();
  }

  void ActivityController::invalidate() noexcept {
    versions_ = {};
  }

  void ActivityController::setWindow(QQuickWindow* window) noexcept {
    window_ = window;
  }

  QString ActivityController::identity(const application::machines::MachineActivityTarget& target) {
    const auto& source = target.source;
    const auto prefix = QStringLiteral("machine:") + QString::number(source.machine.slot) + QLatin1Char(':') + QString::number(source.machine.generation) + QLatin1Char(':') + QString::number(source.generation) + QLatin1Char(':') + QString::number(target.runtime_generation);

    if (const auto* agent = std::get_if<application::machines::MachineActivityTarget::Agent>(&target.owner)) {
      QByteArray session;

      session.reserve(static_cast<qsizetype>(agent->session.size()));
      for (const auto byte : agent->session) {
        session.append(static_cast<char>(byte));
      }

      return prefix + QStringLiteral(":agent:") + QString::number(agent->key.pane_id) + QLatin1Char(':') + QString::number(agent->key.pane_generation) + QLatin1Char(':') + QString::fromLatin1(session.toHex());
    }

    if (const auto* process = std::get_if<application::machines::MachineActivityTarget::Process>(&target.owner)) {
      return prefix + QStringLiteral(":process:") + QString::number(process->pane_id) + QLatin1Char(':') + QString::number(process->pane_generation);
    }

    const auto command = std::get<application::machines::MachineActivityTarget::Command>(target.owner);

    return prefix + QStringLiteral(":command:") + QString::number(command.worktree) + QLatin1Char(':') + QString::number(command.workspace);
  }

  void ActivityController::synchronize() {
    const auto active = store_.machines().active();
    // The top bar names the active machine, so only cards from other machines repeat theirs.
    const auto machine_label = [active](const SourceVersion& version, application::machines::Machines::Slot slot) {
      return slot == active ? std::string_view{} : version.label.view();
    };

    ds::Array<ds::Option<SourceVersion>, application::machines::Machines::capacity> versions;

    for (std::size_t index = 0; index < store_.clients().size(); ++index) {
      const auto& client = store_.clients()[index];
      const auto& row = store_.machines().row(static_cast<application::machines::Machines::Slot>(index));
      if (row.used && row.live && client) {
        versions.atMut(index) = SourceVersion{.source = (*client)->key, .runtime_generation = (*client)->runtime_generation, .agents = (*client)->session.agentRevision(), .workspaces = (*client)->session.workspace_list.revision(), .panes = (*client)->session.paneListRevision(), .connected = row.enabled && (*client)->phase == application::machines::MachinePhase::connected && (*client)->session.ready(), .label = row.label};
      }
    }

    const auto view = store_.session().viewVersion();
    const Selection selection{.slot = active, .tabs = view.active_tab, .panes = view.panes};
    if (versions == versions_ && selection_ == selection) {
      // The cards stay as they are, and so do the mod instances drawing them.
      return;
    }

    ++rebuilds_;
    elements_.begin(ElementSlots::agent_slots);
    ds::Vec<Order::Source, ApplicationAllocator> sources{memory_};

    sources.reserve(application::machines::Machines::capacity);
    for (std::size_t index = 0; index < versions.size(); ++index) {
      if (!versions[index]) {
        continue;
      }

      const auto slot = static_cast<application::machines::Machines::Slot>(index);
      const auto& session = store_.client(slot).session;

      sources.push({.slot = slot, .agents = session.agents(), .workspaces = session.workspace_list});
    }

    Order::Plan order;

    Order::write(sources, active, order);
    QList<QVariantMap> records;

    records.reserve(static_cast<qsizetype>(order.count));
    ds::Vec<RowTarget, ApplicationAllocator> targets{memory_};

    targets.reserve(order.count);
    for (const auto& entry : order.view()) {
      const auto slot = sources[entry.source].slot;
      const auto& source = store_.client(slot);
      const auto& version = versions[slot];
      if (!version) {
        throw std::logic_error{"ActivitySourceWithoutVersion"};
      }

      const auto target = activityTarget(source, entry);
      const auto key = identity(target);
      const AgentRecordContext context{.machine = machine_label(*version, slot), .branch = {}, .connected = version->connected, .coordinator = entry.coordinator, .starts_project = entry.first_in_project, .depth = entry.depth};
      auto record = activityRecord(source.session, entry, context, slot == active);

      keyAgentRecord(record, key, elements_);
      records.append(std::move(record));
      targets.push({.identity = key, .target = target});
    }

    const auto agent_count = static_cast<int>(records.size());
    ds::Vec<ListedProcess, ApplicationAllocator> processes{memory_};

    listProcesses(store_, sources.view(), active, processes);
    if (!processes.empty()) {
      records.append(processHeaderRecord(static_cast<qsizetype>(processes.size())));
    }

    records.reserve(records.size() + static_cast<qsizetype>(processes.size()));
    targets.reserve(targets.size() + processes.size());
    for (const auto& process : processes) {
      const auto slot = sources[process.source].slot;
      const auto& source = store_.client(slot);
      const auto& version = *versions[slot];
      const auto& pane = *process.pane;
      const application::machines::MachineActivityTarget target{.source = source.key, .runtime_generation = source.runtime_generation, .owner = application::machines::MachineActivityTarget::Process{.pane_id = pane.pane_id, .pane_generation = pane.pane_generation}};
      const auto key = identity(target);
      const AgentRecordContext context{.machine = machine_label(version, slot), .connected = version.connected};

      records.append(processRow(source.session, pane, context, slot == active, key));
      targets.push({.identity = key, .target = target});
    }

    targets_ = std::move(targets);
    rows_.reconcile(std::move(records));
    elements_.finish(ElementSlots::agent_slots);
    versions_ = std::move(versions);
    selection_ = selection;
    if (agent_count_ != agent_count) {
      agent_count_ = agent_count;
      emit agentCountChanged();
    }
  }

  const application::machines::MachineActivityTarget* ActivityController::target(const QString& identity) const {
    const auto* const row = std::ranges::find(targets_, identity, &RowTarget::identity);

    return row == targets_.end() ? nullptr : &row->target;
  }

  QString ActivityController::hovered() const {
    return hovered_;
  }

  void ActivityController::hover(const QString& identity, QQuickItem* card) {
    const auto owned_exit = identity.isEmpty() && card != nullptr && hover_card_ == card;
    if (!hover_pending_ && !owned_exit) {
      return;
    }

    if (identity.isEmpty()) {
      if (card != nullptr && hover_card_ != card) {
        return;
      }

      hover_card_.clear();
    } else {
      if (card != nullptr && (card->window() != window_ || !pointer_position_ || !containsActivityPointer(*card, *pointer_position_))) {
        return;
      }

      const auto* listed = target(identity);
      if (listed == nullptr || !activityAvailable(store_, *listed)) {
        return;
      }

      if (card != nullptr) {
        if (hover_card_ != card) {
          hover_card_ = card;
        }
      } else if (hovered_ != identity) {
        hover_card_.clear();
      }
    }

    hover_seen_ = true;
    if (hovered_ != identity) {
      hovered_ = identity;
      emit hoveredChanged();
    }
  }

  void ActivityController::clearHover() {
    hover_card_.clear();

    if (hovered_.isEmpty()) {
      return;
    }

    hovered_.clear();
    emit hoveredChanged();
  }

  void ActivityController::showHover(const QString& identity, std::uint64_t pointer_revision) {
    if (pointer_revision != pointer_revision_) {
      return;
    }

    hovered_ = identity;
    emit hoveredChanged();
  }

  void ActivityController::observePointer(bool hover_input, ds::Option<QPointF> position) {
    ++pointer_revision_;
    pointer_position_ = position;
    hover_pending_ = hover_input;
    hover_seen_ = false;
    if (!hover_input) {
      clearHover();

      return;
    }

    if (hover_reset_queued_) {
      return;
    }

    hover_reset_queued_ = true;
    QMetaObject::invokeMethod(this, [this] {
      hover_pending_ = false;
      hover_reset_queued_ = false;
      if (!hover_seen_) {
        clearHover();
      }
    },
        Qt::QueuedConnection);
  }

  std::uint64_t ActivityController::pointerRevision() const noexcept {
    return pointer_revision_;
  }

}
