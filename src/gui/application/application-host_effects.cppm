export module telar.gui.application:host_effects;

import std;
import telar.tbc;

import telar.gui.features.window;

import telar.gui.foundation.core;
import telar.gui.foundation.system;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: application/agent_acknowledgement.cppm
export {
  namespace telar::gui::application {

    // The agent of the focused pane, as the session's agent list has it.
    struct FocusedAgent {
      std::uint64_t pane_id = 0;
      std::uint64_t pane_generation = 0;
      AgentStatus status = AgentStatus::working;
    };

    class AgentAcknowledgement {
    public:
      [[nodiscard]] ds::Option<AcknowledgeAgent> take(ds::Option<FocusedAgent> agent) noexcept;

    private:
      ds::Option<AcknowledgeAgent> acknowledged_;
    };

  }
}

// Interface: application/command_handler.cppm
export {
  namespace telar::gui::application {

    // Runs the client commands the session leaves to its host, and completes `reply`.
    class ClientCommandHandler {
    public:
      // Running a command may change what the handler drives, as a Rust `FnMut` may.
      virtual void operator()(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) = 0;

    protected:
      ~ClientCommandHandler() = default;
    };

    // The handler of a headless session: it fails every command.
    struct UnsupportedClientCommand final : ClientCommandHandler {
      void operator()(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) override;
    };

  }
}

// Interface: application/host_effects.cppm
export {
  namespace telar::gui::application {

    struct HostEffectLimits {
      static constexpr std::size_t maximum_system_notifications = 240;
    };

    // What the session asks of the desktop it runs in.
    class HostEffects {
    public:
      // Each returns false when the host did not take the request.
      virtual bool postNotification(const NotificationPayload& payload) = 0;
      virtual bool playSound(AgentSound sound) = 0;
      // The session queued input for `pane`. A host that paces frames by input reads its clock here.
      virtual void notePaneInput(features::window::FramePacer::Pane pane) noexcept;

    protected:
      ~HostEffects() = default;
    };

    // The effects of a session without a desktop: it takes nothing.
    struct DiscardHostEffects : HostEffects {
      bool postNotification(const NotificationPayload& payload) noexcept override;

      bool playSound(AgentSound sound) noexcept override;
    };

    // What the session sends the runtime through. The session encodes each message, its tag first,
    // into the storage `buffer` lends, and sends it before it asks for more.
    class RuntimeTransport {
    public:
      // Storage for one message of `size` bytes, which the transport keeps until the next call.
      virtual std::span<Byte> buffer(std::size_t size) = 0;
      virtual void send(std::span<const Byte> message) = 0;
      // Sends a limit report unless the transport is too busy for one; false when it dropped it.
      virtual bool report(std::span<const Byte> message);

      // The session stops showing the pane and is about to detach from it.
      virtual void willDetach(std::uint64_t pane_id);

      // The session found the runtime's stream unusable and stopped reading it.
      virtual void recover(std::string_view reason);

      // Whether the runtime shares images through named memory, which only a local one can.
      [[nodiscard]] virtual bool supportsSharedMemory() const noexcept;

      [[nodiscard]] virtual system::SharedImageSource sharedImage(std::string_view name) const;

    protected:
      ~RuntimeTransport() = default;
    };

  }
}
