#include "application.hpp"
#include "application/host_metrics.hpp"
#include "core/memory.hpp"
#include "machine_client.hpp"
#include "machine_client_key.hpp"
#include "machines/machine_row.hpp"
#include "machines/machine_token.hpp"
#include "machines/machines.hpp"
#include "platform/awake_clock.hpp"
#include "presentation/agent_order.hpp"
#include "remote_bridge.hpp"
#include "runtime_connection.hpp"
#include <QByteArrayView>
#include <QRandomGenerator>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <utility>

namespace telar::gui::qt {

void Application::initializeMachines() {
  const auto slot = machines_.add({.label = {hostname_.constData(), static_cast<std::size_t>(hostname_.size())}, .destination = {}}, Machines::local_slot);
  static_cast<void>(createClient(slot));
}

void Application::configureClients() {
  for (auto &client : clients_) {
    if (!client) {
      continue;
    }

    (*client)->session.configure(configuration_source_.configuration());
    if ((*client)->session.ready()) {
      (*client)->session.configureCadence();
    }
  }
}

void Application::setClientsDisplayRefresh(std::uint16_t fps) {
  for (auto &client : clients_) {
    if (!client) {
      continue;
    }

    (*client)->session.setDisplayRefreshRate(fps);
    if ((*client)->session.ready()) {
      (*client)->session.configureCadence();
    }
  }
}

MachineClient &Application::createClient(Machines::Slot slot) {
  const MachineClientKey key{.machine = machines_.token(slot), .generation = next_client_generation_++};
  auto owned = makeOwned<MachineClient>(memory_, memory_, *this, key);
  auto *client = owned.get();
  client->admitted_program.assign(machines_.row(slot).program.view());
  client->identity = QRandomGenerator::system()->generate64() | std::uint64_t{1};
  client->session.configure(configuration_source_.configuration());
  client->session.setPresented(slot == machines_.active());
  const bool replacing_active = clients_[slot] && slot == machines_.active();
  if (replacing_active) {
    releaseMachineInput();
    showDialog({});
    ++machine_view_revision_;
    forgetMachineView();
  }

  if (auto &previous = clients_[slot]) {
    (*previous)->connection.disconnect(this);
    (*previous)->connection.close();
    previous.reset();
  }

  clients_[slot] = std::move(owned);
  machines_.setLive(slot, true);
  connectMachine(*client);
  if (replacing_active) {
    emit machineChanged();
  }

  return *client;
}

MachineClient &Application::clientAt(Machines::Slot slot) const noexcept {
  const auto &client = clients_[slot];
  if (!client) {
    std::terminate();
  }

  return **client;
}

MachineClient *Application::findClient(MachineClientKey key) const noexcept {
  if (!machines_.contains(key.machine)) {
    return nullptr;
  }

  const auto &client = clients_[key.machine.slot];

  return client && (*client)->key == key ? client->get() : nullptr;
}

GuiSession &Application::session() noexcept {
  return clientAt(machines_.active()).session;
}

const GuiSession &Application::session() const noexcept {
  return clientAt(machines_.active()).session;
}

RuntimeConnection &Application::connection() noexcept {
  return clientAt(machines_.active()).connection;
}

const RuntimeConnection &Application::connection() const noexcept {
  return clientAt(machines_.active()).connection;
}

void Application::connectMachine(MachineClient &client) {
  const auto key = client.key;
  connect(&client.connection, &RuntimeConnection::discovered, this, [this, key](const RemoteDiscovery &discovery) {
    if (auto *source = findClient(key)) {
      discoveredMachine(*source, discovery);
    }
  },
          Qt::DirectConnection);

  connect(&client.connection, &RuntimeConnection::connected, this, [this, key] {
    if (auto *source = findClient(key)) {
      ++source->runtime_generation;
      source->phase = MachinePhase::connected;
      source->needs_setup = false;
      source->session.connected(source->identity);
      summarizeMachine(*source);
      if (key.machine.slot == machines_.active()) {
        emit stateChanged();
      }
    }
  });

  connect(
      &client.connection,
      &RuntimeConnection::payloadReceived,
      this,
      [this, key](QByteArrayView payload) {
        if (auto *source = findClient(key)) {
          consume(*source, payload);
        }
      },
      Qt::DirectConnection);

  connect(
      &client.connection,
      &RuntimeConnection::paneWillDetach,
      this,
      [this, key](qulonglong pane_id) {
        if (findClient(key) != nullptr && key.machine.slot == machines_.active()) {
          emit inputReleasing(pane_id);
        }
      },
      Qt::DirectConnection);

  connect(&client.connection, &RuntimeConnection::disconnected, this, [this, key] {
    if (auto *source = findClient(key)) {
      runtimeDisconnected(*source);
    }
  });

  connect(&client.connection, &RuntimeConnection::errorChanged, this, [this, key] {
    if (findClient(key) != nullptr && key.machine.slot == machines_.active()) {
      emit stateChanged();
    }
  });
}

void Application::selectMachine(MachineToken target) {
  if (!machines_.contains(target) || target.slot == machines_.active() || !machines_.shown(target.slot) || !machines_.row(target.slot).live || !clients_[target.slot]) {
    return;
  }

  pending_activity_.reset();
  clearActivityHover();
  releaseMachineInput();
  showDialog({});
  session().invalidateSuggestion();
  session().setPresented(false);
  ++machine_view_revision_;
  forgetMachineView();
  if (!machines_.select(target.slot)) {
    return;
  }

  emit machineChanged();
  emit machinesChanged();
  synchronizeWorkbenchGeometry();
  session().setPresented(true);
  configureWindow();
  refreshNotifications();
  refresh();
  restoreTerminalFocus();
}

void Application::releaseMachineInput() {
  interruptBindings();
  for (const auto &pane : session().panes()) {
    emit inputReleasing(pane->id);
  }
}

void Application::forgetMachineView() {
  history_timer_.stop();
  graphics_resume_timer_.stop();
  panes_.reconcile({});
  dividers_.reconcile({});
  tabs_.reconcile({});
  workspaces_.reconcile({});
  agents_.reconcile({});
  activity_selection_.reset();
  history_.reconcile({});
  history_view_version_ = 0;
  history_rows_version_ = 0;
  history_directory_source_.clear();
  history_directory_value_.clear();
  history_scope_value_.clear();
  history_tab_name_ = {};
  history_pane_open_ = false;
  error_.clear();
  frame_pacer_.reset();
  if (window_) {
    frame_pacer_.emplace(*window_);
    configureFramePacer();
  }
}

void Application::summarizeMachine(const MachineClient &client) {
  const auto slot = client.key.machine.slot;
  if (findClient(client.key) == nullptr) {
    return;
  }

  const auto &summary = machines_.row(slot);
  const auto &sample = client.session.hostMetrics().sample();
  MachineObservation observation{
      .phase = client.phase,
      .needs_setup = client.needs_setup,
      .attention = summary.attention,
      .metrics_revision = sample.revision,
      .agent_revision = client.session.agentRevision(),
      .workspace_revision = client.session.workspaceList().revision(),
  };
  if (sample.revision != 0) {
    observation.metrics = MachineMetrics{.cpu_percent = sample.cpu_percent, .cpu_count = sample.cpu_count, .memory_used_decigib = sample.memory_used_decigib, .memory_total_decigib = sample.memory_total_decigib};
    if (summary.metrics_revision != sample.revision) {
      observation.now_ns = platform::AwakeClock::nowNanoseconds();
    }
  }

  if (summary.agent_revision != observation.agent_revision) {
    observation.attention = std::ranges::any_of(client.session.agents(), [](const auto &agent) {
      return AgentOrder::attention(agent.status) == AgentOrder::Attention::needs_input;
    });
  }

  if (machines_.summarize(slot, observation)) {
    emit machinesChanged();
  }
}

}
