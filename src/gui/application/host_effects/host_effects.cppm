export module telar.gui.application.host_effects;

import std;
import telar.tbc;

import telar.gui.foundation.text;

import telar.gui.presentation.frame_pacer;

import telar.gui.text.notification_payload;

import telar.gui.core.json_writer;
import telar.gui.foundation.core;
import telar.base.diagnostics;
import telar.base.memory.containers;
import telar.gui.foundation.system;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.vocabulary;

// Interface: application/agent_acknowledgement.cppm
export {
  namespace telar::gui {

    // The agent of the focused pane, as the session's agent list has it.
    struct FocusedAgent {
      std::uint64_t pane_id = 0;
      std::uint64_t pane_generation = 0;
      AgentStatus status = AgentStatus::working;
    };

    class AgentAcknowledgement {
    public:
      [[nodiscard]] std::optional<AcknowledgeAgent> take(std::optional<FocusedAgent> agent) noexcept;

    private:
      std::optional<AcknowledgeAgent> acknowledged_;
    };

  }
}

// Interface: application/command_handler.cppm
export {
  namespace telar::gui {

    // Runs the client commands the session leaves to its host, and completes `reply`.
    class ClientCommandHandler {
    public:
      virtual void operator()(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) const = 0;

    protected:
      ~ClientCommandHandler() = default;
    };

    // The handler of a headless session: it fails every command.
    struct UnsupportedClientCommand final : ClientCommandHandler {
      void operator()(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) const override;
    };

  }
}

// Interface: application/host_effects.cppm
export {
  namespace telar::gui {

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
      virtual void notePaneInput(FramePacer::Pane pane) noexcept;

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

// Interface: application/host_metrics.cppm
export {
  namespace telar::gui {

    class HostMetrics {
    public:
      [[nodiscard]] bool update(const SystemMetrics& sample);

      [[nodiscard]] const SystemMetrics& sample() const noexcept;

      [[nodiscard]] const CpuHistory& history() const noexcept;

      [[nodiscard]] MetricSeverity severity(BarMetric metric) const noexcept;

    private:
      SystemMetrics sample_{};
      CpuHistory history_;
      MetricAlerts alerts_;
    };

  }
}

// Interface: application/limit_reports.cppm
export {
  namespace telar::gui {

    class LimitReports {
    public:
      static constexpr std::size_t capacity = 128;
      static constexpr std::size_t name_capacity = 64;
      static constexpr std::size_t noun_capacity = 32;
      static constexpr std::size_t route_capacity = 32;
      static constexpr std::size_t description_capacity = name_capacity + noun_capacity + 96;
      static constexpr std::uint64_t notice_interval_ms = 60'000;
      static constexpr std::uint64_t report_interval_ms = 1000;

      struct Time {
        std::int64_t awake_ms = 0;
        std::int64_t real_ms = 0;
      };

      struct Row {
        runtime::FixedText<name_capacity> name;
        runtime::FixedText<noun_capacity> noun;
        runtime::FixedText<route_capacity> route;
        std::uint64_t value = 0;
        std::optional<std::uint64_t> requested = std::nullopt;
        std::uint64_t hits = 0;
        std::uint32_t unreported = 0;
        std::int64_t last_ms = 0;
        std::optional<std::int64_t> shown_ms = std::nullopt;
        std::optional<std::int64_t> reported_ms = std::nullopt;

        [[nodiscard]] LimitReach reach() const noexcept;
      };

      struct Slot {
        std::size_t value = 0;
      };

      struct Recorded {
        Slot slot{};
        bool show = false;
      };

      [[nodiscard]] Recorded record(LimitReach reach, Time sampled, std::uint32_t hits);

      [[nodiscard]] std::optional<std::uint32_t> takeReport(Slot slot, std::int64_t awake_ms) noexcept;

      void restoreReport(Slot slot, std::uint32_t hits) noexcept;

      [[nodiscard]] const Row& row(Slot slot) const;

      [[nodiscard]] std::span<const Row> rows() const noexcept;

      [[nodiscard]] std::uint64_t evicted() const noexcept;

      [[nodiscard]] static BoundedText<description_capacity> describe(LimitReach reach, std::uint64_t hits);

    private:
      template <typename Number>
      [[nodiscard]] static Number saturatedAdd(Number left, Number right) noexcept;

      [[nodiscard]] static bool elapsed(std::int64_t now_ms, std::int64_t since_ms, std::uint64_t interval_ms) noexcept;

      static void appendNoun(BoundedText<description_capacity>& text, std::string_view noun);

      [[nodiscard]] std::optional<std::size_t> find(std::string_view name) const noexcept;

      std::size_t insert(std::string_view name);

      [[nodiscard]] std::size_t oldest() const noexcept;

      std::array<Row, capacity> rows_{};
      std::size_t count_ = 0;
      std::uint64_t evicted_ = 0;
    };

  }
}
