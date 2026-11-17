#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "terminal/screen.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/machines/machine_client_key.hpp"
#include "ui/foundation/machines/remote_bridge.hpp"
#include "ui/foundation/machines/runtime_connection.hpp"
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
import telar.platform.process;

namespace telar::gui::qt {

  namespace {

    // A remote's discovery names the shell and home a new pane starts in, unless the window was
    // launched with a command of its own, which only takes the home.
    void discovered(MachineClient& client, const RemoteDiscovery& discovery) {
      if (client.named_launch) {
        client.session.setLaunchDirectory(discovery.home());

        return;
      }

      const auto path = discovery.shell();
      const std::array arguments{path, std::string_view{"-l"}, std::string_view{"-i"}};

      client.session.setLaunch({.cwd = discovery.home(), .arguments = std::span{arguments}.first(!runtime::loginShellScript(path).empty() ? arguments.size() : 1)});
    }

  }

  void ApplicationController::initializeMachines() {
    const auto slot = store_.machines().add({.label = {hostname_.constData(), static_cast<std::size_t>(hostname_.size())}, .destination = {}}, Machines::local_slot);

    static_cast<void>(createClient(slot));
  }

  void ApplicationController::configureClients() {
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

  void ApplicationController::setClientsDisplayRefresh(std::uint16_t fps) {
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

  MachineClient& ApplicationController::createClient(Machines::Slot slot) {
    const auto key = store_.admission(slot);
    const MachineEffects::Sinks sinks{
        .machines = store_.machines(),
        .clients = store_.clients(),
        .desktop = effects_,
        .sound_owner = sound_owner_,
        .frame_pacer = frames_.pacer(),
    };

    auto owned = makeOwned<MachineClient>(memory_, memory_, sinks, key);
    auto* client = owned.get();

    client->admitted_program.assign(store_.machines().row(slot).program.view());
    client->identity = QRandomGenerator::system()->generate64() | std::uint64_t{1};
    client->session.configure(configuration_source_.configuration());
    client->session.setPresented(slot == store_.machines().active());
    const bool replacing_active = store_.clients()[slot] && slot == store_.machines().active();
    if (replacing_active) {
      releaseMachineInput();
      dialogs_.show(Dialog::none);
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

  MachineClient& ApplicationController::clientAt(Machines::Slot slot) const noexcept {
    return store_.client(slot);
  }

  MachineClient* ApplicationController::findClient(MachineClientKey key) const noexcept {
    return store_.find(key);
  }

  GuiSession& ApplicationController::session() noexcept {
    return store_.session();
  }

  const GuiSession& ApplicationController::session() const noexcept {
    return store_.session();
  }

  RuntimeConnection& ApplicationController::connection() noexcept {
    return store_.connection();
  }

  const RuntimeConnection& ApplicationController::connection() const noexcept {
    return store_.connection();
  }

  void ApplicationController::connectMachine(Machines::Slot slot) {
    auto& client = clientAt(slot);
    const auto key = client.key;

    connect(&client.connection, &RuntimeConnection::discovered, this, [this, key](const RemoteDiscovery& discovery) {
      if (auto* source = findClient(key)) {
        discovered(*source, discovery);
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
          status_.publish();
          status_.publishMetrics();
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
            terminals_.releaseInput(pane_id);
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
          link_status_.publish();
        }
      }
    });

    connect(&client.connection, &RuntimeConnection::errorChanged, this, [this, key] {
      if (findClient(key) != nullptr && key.machine.slot == store_.machines().active()) {
        status_.publish();
      }
    });
  }

  void ApplicationController::selectMachine(MachineToken target) {
    if (!store_.machines().contains(target) || target.slot == store_.machines().active() || !store_.machines().shown(target.slot) || !store_.machines().row(target.slot).live || !store_.clients()[target.slot]) {
      return;
    }

    pending_activity_.reset();
    activity_.clearHover();
    releaseMachineInput();
    dialogs_.show(Dialog::none);
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
    display_.layoutWorkbench();
    session().setPresented(true);
    configureWindow();
    notifications_.refresh();
    refresh();
    restoreTerminalFocus();
  }

  void ApplicationController::releaseMachineInput() {
    interruptBindings();
    for (const auto& pane : session().panes()) {
      terminals_.releaseInput(pane->id);
    }
  }

  void ApplicationController::forgetMachineView() {
    history_.forget();
    graphics_resume_timer_.stop();
    panes_.forget();
    tabs_.forget();
    workspaces_.forget();
    activity_.forget();
    status_.clear();
    frames_.restart();
  }

  void ApplicationController::summarizeMachine(MachineClientKey key) {
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
