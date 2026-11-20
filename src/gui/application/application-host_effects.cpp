module telar.gui.application;

import std;
import telar.gui.foundation.system;
import telar.gui.foundation.core;
import telar.tbc;
import telar.gui.features.window;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::application {

  ds::Option<AcknowledgeAgent> AgentAcknowledgement::take(ds::Option<FocusedAgent> agent) noexcept {
    if (!agent) {
      return ds::none;
    }

    const bool already = acknowledged_ && acknowledged_->pane_id == agent->pane_id && acknowledged_->pane_generation == agent->pane_generation;

    if (agent->status != AgentStatus::done) {
      if (already) {
        acknowledged_.reset();
      }

      return ds::none;
    }

    if (already) {
      return ds::none;
    }

    acknowledged_ = AcknowledgeAgent{.pane_id = agent->pane_id, .pane_generation = agent->pane_generation};

    return acknowledged_;
  }

  void UnsupportedClientCommand::operator()([[maybe_unused]] const ClientCommand& message, tbc::mut_a<CompleteClientCommand> reply) {
    reply.status = ClientCommandStatus::failed;
    reply.text = "Command is not supported by this client";
  }

  void HostEffects::notePaneInput([[maybe_unused]] features::window::FramePacer::Pane pane) noexcept {}

  bool DiscardHostEffects::postNotification([[maybe_unused]] const NotificationPayload& payload) noexcept {
    return false;
  }

  bool DiscardHostEffects::playSound([[maybe_unused]] AgentSound sound) noexcept {
    return false;
  }

  bool BasicRuntimeTransport::report(std::span<const Byte> message) {
    send(message);

    return true;
  }

  void BasicRuntimeTransport::willDetach([[maybe_unused]] std::uint64_t pane_id) {}

  void BasicRuntimeTransport::recover([[maybe_unused]] std::string_view reason) {}

  bool BasicRuntimeTransport::supportsSharedMemory() const noexcept {
    return false;
  }

  system::SharedImageSource BasicRuntimeTransport::sharedImage([[maybe_unused]] std::string_view name) const {
    throw EncodingError{"Shared graphics was not negotiated"};
  }

}
