#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "machine_client.hpp"
#include "machine_client_key.hpp"
#include "remote_bridge.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_config/graphics/limits.hpp"
#include "terminal/screen.hpp"
#include "ui/app/application.hpp"
#include "ui/app/runtime_connection.hpp"
#include <QByteArrayView>
#include <QRandomGenerator>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <tuple>
#include <utility>
#include <variant>

#include "core/memory.hpp"

import telar.gui.machines.picker;
import telar.gui.platform.awake_clock;
import telar.gui.presentation.activity_order;

namespace telar::gui::qt {

  void Application::initializeMachines() {
    const auto slot = store_.machines().add({.label = {hostname_.constData(), static_cast<std::size_t>(hostname_.size())}, .destination = {}}, Machines::local_slot);

    static_cast<void>(createClient(slot));
  }

  void Application::configureClients() {
    for (auto& client : store_.clients()) {
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
    for (auto& client : store_.clients()) {
      if (!client) {
        continue;
      }

      (*client)->session.setDisplayRefreshRate(fps);
      if ((*client)->session.ready()) {
        (*client)->session.configureCadence();
      }
    }
  }

  MachineClient& Application::createClient(Machines::Slot slot) {
    const auto key = store_.admission(slot);
    auto owned = makeOwned<MachineClient>(memory_, memory_, *this, key);
    auto* client = owned.get();

    client->admitted_program.assign(store_.machines().row(slot).program.view());
    client->identity = QRandomGenerator::system()->generate64() | std::uint64_t{1};
    client->session.configure(configuration_source_.configuration());
    client->session.setPresented(slot == store_.machines().active());
    const bool replacing_active = store_.clients()[slot] && slot == store_.machines().active();
    if (replacing_active) {
      releaseMachineInput();
      showDialog(Dialog::none);
      store_.advanceMachineView();
      forgetMachineView();
    }

    if (auto& previous = store_.clients()[slot]) {
      (*previous)->connection.disconnect(this);
      (*previous)->connection.close();
      previous.reset();
    }

    store_.clients()[slot] = std::move(owned);
    store_.machines().setLive(slot, true);
    connectMachine(slot);
    if (replacing_active) {
      emit machineChanged();
    }

    return clientAt(slot);
  }

  MachineClient& Application::clientAt(Machines::Slot slot) const noexcept {
    return store_.client(slot);
  }

  MachineClient* Application::findClient(MachineClientKey key) const noexcept {
    return store_.find(key);
  }

  GuiSession& Application::session() noexcept {
    return store_.session();
  }

  const GuiSession& Application::session() const noexcept {
    return store_.session();
  }

  RuntimeConnection& Application::connection() noexcept {
    return store_.connection();
  }

  const RuntimeConnection& Application::connection() const noexcept {
    return store_.connection();
  }

  void Application::connectMachine(Machines::Slot slot) {
    auto& client = clientAt(slot);
    const auto key = client.key;

    connect(&client.connection, &RuntimeConnection::discovered, this, [this, key](const RemoteDiscovery& discovery) {
      if (auto* source = findClient(key)) {
        discoveredMachine(*source, discovery);
      }
    },
        Qt::DirectConnection);

    connect(&client.connection, &RuntimeConnection::connected, this, [this, key] {
      if (auto* source = findClient(key)) {
        ++source->runtime_generation;
        source->phase = MachinePhase::connected;
        source->needs_setup = false;
        source->session.connected(source->identity, RuntimeProtocol::readsRows(source->connection.schema()));
        summarizeMachine(source->key);
        if (key.machine.slot == store_.machines().active()) {
          emit stateChanged();
          emit hostMetricsChanged();
        }
      }
    });

    connect(
        &client.connection,
        &RuntimeConnection::payloadReceived,
        this,
        [this, key](QByteArrayView payload) {
          if (auto* source = findClient(key)) {
            consume(*source, payload);
          }
        },
        Qt::DirectConnection
    );

    connect(
        &client.connection,
        &RuntimeConnection::paneWillDetach,
        this,
        [this, key](qulonglong pane_id) {
          if (findClient(key) != nullptr && key.machine.slot == store_.machines().active()) {
            emit inputReleasing(pane_id);
          }
        },
        Qt::DirectConnection
    );

    connect(&client.connection, &RuntimeConnection::disconnected, this, [this, key] {
      if (auto* source = findClient(key)) {
        runtimeDisconnected(*source);
      }
    });

    connect(&client.connection, &RuntimeConnection::linkChanged, this, [this, key] {
      if (auto* source = findClient(key)) {
        source->phase = source->connection.link().phase;
        source->needs_setup = source->connection.link().setup_repairs;
        summarizeMachine(source->key);
        if (key.machine.slot == store_.machines().active()) {
          emit runtimeLinkChanged();
        }
      }
    });

    connect(&client.connection, &RuntimeConnection::errorChanged, this, [this, key] {
      if (findClient(key) != nullptr && key.machine.slot == store_.machines().active()) {
        emit stateChanged();
      }
    });
  }

  void Application::selectMachine(MachineToken target) {
    if (!store_.machines().contains(target) || target.slot == store_.machines().active() || !store_.machines().shown(target.slot) || !store_.machines().row(target.slot).live || !store_.clients()[target.slot]) {
      return;
    }

    pending_activity_.reset();
    clearActivityHover();
    releaseMachineInput();
    showDialog(Dialog::none);
    session().invalidateSuggestion();
    session().setPresented(false);
    store_.advanceMachineView();
    forgetMachineView();
    if (!store_.machines().select(target.slot)) {
      return;
    }

    connection().resumeSession();
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
    for (const auto& pane : session().panes()) {
      emit inputReleasing(pane->id);
    }
  }

  void Application::forgetMachineView() {
    history_.forget();
    graphics_resume_timer_.stop();
    panes_.reconcile({});
    dividers_.reconcile({});
    tabs_.forget();
    workspaces_.forget();
    agents_.reconcile({});
    activity_selection_.reset();
    error_.clear();
    frame_pacer_.reset();
    if (window_) {
      frame_pacer_.emplace(*window_);
      configureFramePacer();
    }
  }

  void Application::summarizeMachine(MachineClientKey key) {
    const auto slot = key.machine.slot;
    const auto* const found = findClient(key);
    if (found == nullptr) {
      return;
    }

    const auto& client = *found;
    const auto& summary = store_.machines().row(slot);
    const auto& sample = client.session.hostMetrics().sample();
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
      observation.attention = std::ranges::any_of(client.session.agents(), [](const auto& agent) {
        return AgentOrder::attention(agent.status) == AgentOrder::Attention::needs_input;
      });
    }

    if (store_.machines().summarize(slot, observation)) {
      emit machinesChanged();
    }
  }

}
