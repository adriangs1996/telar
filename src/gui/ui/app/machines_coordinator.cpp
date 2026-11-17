#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machines_coordinator.hpp"
#include "core/memory.hpp"
#include "dialogs.hpp"
#include "frame_presenter.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/machines/remote_bridge.hpp"
#include "ui/foundation/machines/runtime_connection.hpp"
#include "ui/foundation/models/projection.hpp"
#include "window_display.hpp"
#include "window_status.hpp"
#include <QByteArrayView>
#include <QCryptographicHash>
#include <QDir>
#include <QRandomGenerator>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <optional>
#include <span>
#include <string_view>
#include <utility>

import telar.gui.machines.picker;
import telar.gui.presentation.activity_order;
import telar.platform.process;
import telar.gui.application;
import telar.wire.vocabulary;

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

  MachinesCoordinator::MachinesCoordinator(ApplicationAllocator& memory, Store& store, ConfigurationSource& configuration, application::HostEffects& desktop, FramePresenter& frames, WindowDisplay& display, WindowStatus& status, Dialogs& dialogs, MachinesHost& host, QByteArray hostname, QObject* parent)
      : QObject(parent),
        memory_(memory),
        store_(store),
        configuration_source_(configuration),
        desktop_(desktop),
        frames_(frames),
        display_(display),
        status_(status),
        dialogs_(dialogs),
        host_(host),
        hostname_(std::move(hostname)) {}

  void MachinesCoordinator::release(MachineClient& client) {
    host_.dismiss(client);
    client.connection.disconnect(this);
    client.connection.close();
  }

  void MachinesCoordinator::shutdown() {
    for (auto& client : store_.clients()) {
      if (client) {
        release(**client);
      }
    }
  }

  void MachinesCoordinator::markDisconnected(MachineClient& client) {
    client.session.disconnected();
    static_cast<void>(client.session.settlePresentation());
    client.phase = client.connection.link().phase;
    client.needs_setup = client.connection.link().setup_repairs;
    summarize(client.key);
  }

  void MachinesCoordinator::publishList() {
    emit listChanged();
  }

  void MachinesCoordinator::initialize() {
    const auto slot = store_.machines().add({.label = {hostname_.constData(), static_cast<std::size_t>(hostname_.size())}, .destination = {}}, Machines::local_slot);

    static_cast<void>(createClient(slot));
    const system::login_shell::Command shell;
    const auto directory = QDir::currentPath().toUtf8();

    store_.session().setLaunch(Launch{
        .cwd = {
            directory.constData(),
            static_cast<std::size_t>(directory.size()),
        },
        .arguments = shell.arguments(),
    });
  }

  void MachinesCoordinator::configure() {
    for (auto& client : store_.clients()) {
      if (!client) {
        continue;
      }

      (*client)->session.configure(configuration_source_.configuration());
      if ((*client)->session.ready()) {
        application::window::pace((*client)->session);
      }
    }
  }

  void MachinesCoordinator::setDisplayRefresh(std::uint16_t fps) {
    for (auto& client : store_.clients()) {
      if (!client) {
        continue;
      }

      application::window::setRefreshRate((*client)->session, fps);
      if ((*client)->session.ready()) {
        application::window::pace((*client)->session);
      }
    }
  }

  MachineClient& MachinesCoordinator::createClient(Machines::Slot slot) {
    const auto key = store_.admission(slot);
    const MachineEffects::Sinks sinks{
        .machines = store_.machines(),
        .clients = store_.clients(),
        .desktop = desktop_,
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
      host_.releaseInput();
      dialogs_.show(Store::Dialog::none);
      store_.advanceMachineView();
      host_.forgetView();
    }

    if (auto& previous = store_.clients()[slot]) {
      release(**previous);
      previous.reset();
    }

    store_.clients()[slot] = std::move(owned);
    store_.machines().setLive(slot, true);
    connectMachine(slot);
    if (replacing_active) {
      emit changed();
    }

    return clientAt(slot);
  }

  MachineClient& MachinesCoordinator::clientAt(Machines::Slot slot) const noexcept {
    return store_.client(slot);
  }

  MachineClient* MachinesCoordinator::findClient(MachineClientKey key) const noexcept {
    return store_.find(key);
  }

  void MachinesCoordinator::connectMachine(Machines::Slot slot) {
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
        summarize(source->key);
        if (key.machine.slot == store_.machines().active()) {
          status_.publish();
          status_.publishMetrics();
        }
      }
    });

    host_.attend(client);

    connect(&client.connection, &RuntimeConnection::linkChanged, this, [this, key] {
      if (auto* source = findClient(key)) {
        source->phase = source->connection.link().phase;
        source->needs_setup = source->connection.link().setup_repairs;
        summarize(source->key);
        if (key.machine.slot == store_.machines().active()) {
          emit linkChanged();
        }
      }
    });

    connect(&client.connection, &RuntimeConnection::errorChanged, this, [this, key] {
      if (findClient(key) != nullptr && key.machine.slot == store_.machines().active()) {
        status_.publish();
      }
    });
  }

  void MachinesCoordinator::select(MachineToken target) {
    if (!store_.machines().contains(target) || target.slot == store_.machines().active() || !store_.machines().shown(target.slot) || !store_.machines().row(target.slot).live || !store_.clients()[target.slot]) {
      return;
    }

    emit selecting();
    host_.releaseInput();
    dialogs_.show(Store::Dialog::none);
    application::palette::discard(store_.session());
    store_.session().setPresented(false);
    store_.advanceMachineView();
    host_.forgetView();
    if (!store_.machines().select(target.slot)) {
      return;
    }

    store_.connection().resumeSession();
    emit changed();
    emit listChanged();
    display_.layoutWorkbench();
    store_.session().setPresented(true);
    host_.presentMachine();
  }

  void MachinesCoordinator::summarize(MachineClientKey key) {
    const auto slot = key.machine.slot;
    const auto* const found = findClient(key);
    if (found == nullptr) {
      return;
    }

    const auto& client = *found;
    const auto& summary = store_.machines().row(slot);
    const auto& sample = application::status_bar::metrics(client.session).sample();
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
        observation.now_ns = system::AwakeClock::nowNanoseconds();
      }
    }

    if (summary.agent_revision != observation.agent_revision) {
      observation.attention = std::ranges::any_of(client.session.agents(), [](const auto& agent) {
        return AgentOrder::attention(agent.status) == AgentOrder::Attention::needs_input;
      });
    }

    if (store_.machines().summarize(slot, observation)) {
      emit listChanged();
    }
  }

  void MachinesCoordinator::move(int delta) {
    auto slot = static_cast<int>(store_.machines().active());

    for (std::size_t step = 0; step < Machines::capacity; ++step) {
      slot = (slot + delta + static_cast<int>(Machines::capacity)) % static_cast<int>(Machines::capacity);
      const auto candidate = static_cast<Machines::Slot>(slot);
      if (store_.machines().shown(candidate) && store_.machines().row(candidate).live && store_.clients()[candidate]) {
        select(store_.machines().token(candidate));

        return;
      }
    }
  }

  void MachinesCoordinator::open(const QString& endpoint) {
    auto& client = clientAt(Machines::local_slot);
    const auto path = endpoint.toUtf8();

    client.identity_lease.emplace(std::string_view{path.constData(), static_cast<std::size_t>(path.size())});
    QCryptographicHash hash{QCryptographicHash::Sha256};
    constexpr auto identity_namespace = std::to_array("telar-gui-window-v1");
    const auto canonical_endpoint = client.identity_lease->endpoint();

    hash.addData(QByteArrayView{identity_namespace.data(), static_cast<qsizetype>(identity_namespace.size())});
    hash.addData(QByteArrayView{canonical_endpoint.data(), static_cast<qsizetype>(canonical_endpoint.size())});
    constexpr char separator = '\0';

    hash.addData(QByteArrayView{&separator, 1});
    const auto slot = static_cast<char>(client.identity_lease->slot());

    hash.addData(QByteArrayView{&slot, 1});
    const auto digest = hash.result();
    auto identity_bytes = byteView({digest.constData(), static_cast<std::size_t>(digest.size())}).first(sizeof(std::uint64_t));

    client.identity = u64::decode(identity_bytes) | std::uint64_t{1};
    client.connection.open(endpoint);
  }

  QVariantMap MachinesCoordinator::context() const {
    return {
        {QStringLiteral("label"), toQString(store_.machines().row(store_.machines().active()).label.view())},
        {QStringLiteral("attention"), store_.machines().attentionElsewhere()},
    };
  }

  void MachinesCoordinator::soundFinished([[maybe_unused]] std::optional<CommandFailure> failure) {
    const auto owner = std::exchange(sound_owner_, std::nullopt);
    auto* client = owner ? findClient(*owner) : nullptr;
    if (client == nullptr) {
      return;
    }

    try {
      client->session.completeAgentSound();
    } catch (const std::exception& error) {
      status_.fail(error);
    }
  }

}
