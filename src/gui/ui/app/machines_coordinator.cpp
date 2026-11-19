#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machines_coordinator.hpp"
#include "dialogs.hpp"
#include "foundation/core/memory.hpp"
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

import telar.platform.process;
import telar.gui.application;
import telar.wire.vocabulary;
import telar.base.ds;

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
      const ds::Array arguments{path, std::string_view{"-l"}, std::string_view{"-i"}};

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
    for (auto& client : store_.clientsMut().viewMut()) {
      if (client) {
        release(client.getMut().getMut());
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
    const auto slot = store_.machinesMut().add({.label = {hostname_.constData(), static_cast<std::size_t>(hostname_.size())}, .destination = {}}, application::machines::Machines::local_slot);

    static_cast<void>(createClient(slot));
    const system::login_shell::Command shell;
    const auto directory = QDir::currentPath().toUtf8();

    store_.sessionMut().setLaunch(Launch{
        .cwd = {
            directory.constData(),
            static_cast<std::size_t>(directory.size()),
        },
        .arguments = shell.arguments(),
    });
  }

  void MachinesCoordinator::configure() {
    // By slot: a session's effects reach the store its client lies in.
    for (std::size_t slot = 0; slot < store_.clients().size(); ++slot) {
      if (!store_.clients()[slot]) {
        continue;
      }

      application::configuration::configure(store_.clientsMut().atMut(slot).getMut().getMut().session, configuration_source_.configuration());
      if (store_.clients()[slot]->get().session.ready()) {
        application::window::pace(store_.clientsMut().atMut(slot).getMut().getMut().session);
      }
    }
  }

  void MachinesCoordinator::setDisplayRefresh(std::uint16_t fps) {
    // By slot: a session's effects reach the store its client lies in.
    for (std::size_t slot = 0; slot < store_.clients().size(); ++slot) {
      if (!store_.clients()[slot]) {
        continue;
      }

      application::window::setRefreshRate(store_.clientsMut().atMut(slot).getMut().getMut().session, fps);
      if (store_.clients()[slot]->get().session.ready()) {
        application::window::pace(store_.clientsMut().atMut(slot).getMut().getMut().session);
      }
    }
  }

  MachineClient& MachinesCoordinator::createClient(application::machines::Machines::Slot slot) {
    const auto key = store_.admission(slot);
    const MachineEffects::Sinks sinks{
        .machines = store_.machines(),
        .clients = store_.clients(),
        .desktop = desktop_,
        .sound_owner = sound_owner_,
        .frame_pacer = frames_.pacer(),
    };

    auto owned = ds::makeBox<MachineClient>(memory_, memory_, sinks, key);
    auto* client = &owned.getMut();

    client->admitted_program.assign(store_.machines().row(slot).program.view());
    client->identity = QRandomGenerator::system()->generate64() | std::uint64_t{1};
    application::configuration::configure(client->session, configuration_source_.configuration());
    client->session.setPresented(slot == store_.machines().active());
    const bool replacing_active = store_.clients()[slot] && slot == store_.machines().active();
    if (replacing_active) {
      host_.releaseInput();
      dialogs_.show(Store::Dialog::none);
      store_.advanceMachineView();
      host_.forgetView();
    }

    if (auto& previous = store_.clientsMut().atMut(slot)) {
      release(previous.getMut().getMut());
      previous.reset();
    }

    store_.clientsMut().atMut(slot) = std::move(owned);
    store_.machinesMut().setLive(slot, true);
    connectMachine(slot);
    if (replacing_active) {
      emit changed();
    }

    return clientAtMut(slot);
  }

  const MachineClient& MachinesCoordinator::clientAt(application::machines::Machines::Slot slot) const noexcept {
    return store_.client(slot);
  }

  MachineClient& MachinesCoordinator::clientAtMut(application::machines::Machines::Slot slot) noexcept {
    return store_.clientMut(slot);
  }

  const MachineClient* MachinesCoordinator::findClient(application::machines::MachineClientKey key) const noexcept {
    return store_.find(key);
  }

  MachineClient* MachinesCoordinator::findClientMut(application::machines::MachineClientKey key) noexcept {
    return store_.findMut(key);
  }

  void MachinesCoordinator::connectMachine(application::machines::Machines::Slot slot) {
    auto& client = clientAtMut(slot);
    const auto key = client.key;

    connect(&client.connection, &RuntimeConnection::discovered, this, [this, key](const RemoteDiscovery& discovery) {
      if (auto* source = findClientMut(key)) {
        discovered(*source, discovery);
      }
    },
        Qt::DirectConnection);

    connect(&client.connection, &RuntimeConnection::connected, this, [this, key] {
      if (auto* source = findClientMut(key)) {
        ++source->runtime_generation;
        source->phase = application::machines::MachinePhase::connected;
        source->needs_setup = false;
        source->session.connected(source->identity, application::RuntimeProtocol::readsRows(source->connection.schema()), application::RuntimeProtocol::supports(source->connection.schema(), ClientTag::query_monitor));
        summarize(source->key);
        if (key.machine.slot == store_.machines().active()) {
          status_.publish();
          status_.publishMetrics();
        }
      }
    });

    host_.attend(client);

    connect(&client.connection, &RuntimeConnection::linkChanged, this, [this, key] {
      if (auto* source = findClientMut(key)) {
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

  void MachinesCoordinator::select(application::machines::MachineToken target) {
    if (!store_.machines().contains(target) || target.slot == store_.machines().active() || !store_.machines().shown(target.slot) || !store_.machines().row(target.slot).live || !store_.clients()[target.slot]) {
      return;
    }

    emit selecting();
    host_.releaseInput();
    dialogs_.show(Store::Dialog::none);
    application::palette::discard(store_.sessionMut());
    store_.sessionMut().setPresented(false);
    store_.advanceMachineView();
    host_.forgetView();
    if (!store_.machinesMut().select(target.slot)) {
      return;
    }

    store_.connectionMut().resumeSession();
    emit changed();
    emit listChanged();
    display_.layoutWorkbench();
    store_.sessionMut().setPresented(true);
    host_.presentMachine();
  }

  void MachinesCoordinator::summarize(application::machines::MachineClientKey key) {
    const auto slot = key.machine.slot;
    const auto* const found = findClient(key);
    if (found == nullptr) {
      return;
    }

    const auto& client = *found;
    const auto& summary = store_.machines().row(slot);
    const auto& sample = application::status_bar::metrics(client.session).sample();
    application::machines::MachineObservation observation{
        .phase = client.phase,
        .needs_setup = client.needs_setup,
        .attention = summary.attention,
        .metrics_revision = sample.revision,
        .agent_revision = client.session.agentRevision(),
        .workspace_revision = client.session.workspace_list.revision(),
    };

    if (sample.revision != 0) {
      observation.metrics = application::machines::MachineMetrics{.cpu_percent = sample.cpu_percent, .cpu_count = sample.cpu_count, .memory_used_decigib = sample.memory_used_decigib, .memory_total_decigib = sample.memory_total_decigib};
      if (summary.metrics_revision != sample.revision) {
        observation.now_ns = system::AwakeClock::nowNanoseconds();
      }
    }

    if (summary.agent_revision != observation.agent_revision) {
      observation.attention = std::ranges::any_of(client.session.agents(), [](const auto& agent) {
        return application::activity::AgentOrder::attention(agent.status) == application::activity::AgentOrder::Attention::needs_input;
      });
    }

    if (store_.machinesMut().summarize(slot, observation)) {
      emit listChanged();
    }
  }

  void MachinesCoordinator::move(int delta) {
    auto slot = static_cast<int>(store_.machines().active());

    for (std::size_t step = 0; step < application::machines::Machines::capacity; ++step) {
      slot = (slot + delta + static_cast<int>(application::machines::Machines::capacity)) % static_cast<int>(application::machines::Machines::capacity);
      const auto candidate = static_cast<application::machines::Machines::Slot>(slot);
      if (store_.machines().shown(candidate) && store_.machines().row(candidate).live && store_.clients()[candidate]) {
        select(store_.machines().token(candidate));

        return;
      }
    }
  }

  void MachinesCoordinator::open(const QString& endpoint) {
    auto& client = clientAtMut(application::machines::Machines::local_slot);
    const auto path = endpoint.toUtf8();

    client.identity_lease.emplace(std::string_view{path.constData(), static_cast<std::size_t>(path.size())});
    QCryptographicHash hash{QCryptographicHash::Sha256};
    constexpr auto identity_namespace = ds::toArray("telar-gui-window-v1");
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

  void MachinesCoordinator::soundFinished([[maybe_unused]] ds::Option<CommandFailure> failure) {
    const auto owner = std::exchange(sound_owner_, ds::none);
    auto* client = owner ? findClientMut(*owner) : nullptr;
    if (client == nullptr) {
      return;
    }

    try {
      application::notifications::completeSound(client->session);
    } catch (const std::exception& error) {
      status_.fail(error);
    }
  }

}
