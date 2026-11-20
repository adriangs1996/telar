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
      virtual void operator()(const ClientCommand& message, tbc::mut_a<CompleteClientCommand> reply) = 0;

    protected:
      ClientCommandHandler() noexcept = default;
      ClientCommandHandler(const ClientCommandHandler&) noexcept = default;
      ClientCommandHandler(ClientCommandHandler&&) noexcept = default;
      ClientCommandHandler& operator=(const ClientCommandHandler&) noexcept = default;
      ClientCommandHandler& operator=(ClientCommandHandler&&) noexcept = default;
      ~ClientCommandHandler() = default;
    };

    // The handler of a headless session: it fails every command.
    struct UnsupportedClientCommand final : ClientCommandHandler {
      void operator()(const ClientCommand& message, tbc::mut_a<CompleteClientCommand> reply) override;
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
      HostEffects() noexcept = default;
      HostEffects(const HostEffects&) noexcept = default;
      HostEffects(HostEffects&&) noexcept = default;
      HostEffects& operator=(const HostEffects&) noexcept = default;
      HostEffects& operator=(HostEffects&&) noexcept = default;
      ~HostEffects() = default;
    };

    // The effects of a session without a desktop: it takes nothing.
    struct DiscardHostEffects : HostEffects {
      DiscardHostEffects() noexcept = default;
      DiscardHostEffects(const DiscardHostEffects&) noexcept = default;
      DiscardHostEffects(DiscardHostEffects&&) noexcept = default;
      DiscardHostEffects& operator=(const DiscardHostEffects&) noexcept = default;
      DiscardHostEffects& operator=(DiscardHostEffects&&) noexcept = default;
      // Hosts derive from it to take only some requests.
      virtual ~DiscardHostEffects() = default;

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
      virtual bool report(std::span<const Byte> message) = 0;

      // The session stops showing the pane and is about to detach from it.
      virtual void willDetach(std::uint64_t pane_id) = 0;

      // The session found the runtime's stream unusable and stopped reading it.
      virtual void recover(std::string_view reason) = 0;

      // Whether the runtime shares images through named memory, which only a local one can.
      [[nodiscard]] virtual bool supportsSharedMemory() const noexcept = 0;

      [[nodiscard]] virtual system::SharedImageSource sharedImage(std::string_view name) const = 0;

    protected:
      RuntimeTransport() noexcept = default;
      RuntimeTransport(const RuntimeTransport&) noexcept = default;
      RuntimeTransport(RuntimeTransport&&) noexcept = default;
      RuntimeTransport& operator=(const RuntimeTransport&) noexcept = default;
      RuntimeTransport& operator=(RuntimeTransport&&) noexcept = default;
      ~RuntimeTransport() = default;
    };

    // A transport with nothing past sending: a report goes as any message, nothing happens before a
    // detach or a recovery, and images never come through shared memory.
    class BasicRuntimeTransport : public RuntimeTransport {
    public:
      bool report(std::span<const Byte> message) override;
      void willDetach(std::uint64_t pane_id) override;
      void recover(std::string_view reason) override;
      [[nodiscard]] bool supportsSharedMemory() const noexcept override;
      [[nodiscard]] system::SharedImageSource sharedImage(std::string_view name) const override;

    protected:
      BasicRuntimeTransport() noexcept = default;
      BasicRuntimeTransport(const BasicRuntimeTransport&) noexcept = default;
      BasicRuntimeTransport(BasicRuntimeTransport&&) noexcept = default;
      BasicRuntimeTransport& operator=(const BasicRuntimeTransport&) noexcept = default;
      BasicRuntimeTransport& operator=(BasicRuntimeTransport&&) noexcept = default;
      ~BasicRuntimeTransport() = default;
    };

  }
}
