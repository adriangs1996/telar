export module telar.runtime.agents.description_generator;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.terminal.osc_scanner;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;

import telar.platform.events;
import telar.platform.process;

import telar.wire.vocabulary;
import telar.base.ds;

// Interface: agents/description_capture.cppm
export {
  namespace telar::runtime {

    inline constexpr std::size_t description_query_capacity = 4096;
    using DescriptionQuery = SensitiveText<description_query_capacity>;

    class DescriptionCapture {
    public:
      DescriptionCapture() = default;
      ~DescriptionCapture();
      DescriptionCapture(const DescriptionCapture&) = default;
      DescriptionCapture& operator=(const DescriptionCapture&) = default;
      DescriptionCapture(DescriptionCapture&&) = default;
      DescriptionCapture& operator=(DescriptionCapture&&) = default;

      bool feed(std::span<const Byte> input);
      void clear() noexcept;
      [[nodiscard]] DescriptionQuery normalized() const;

    private:
      static constexpr Byte clear_line = 0x15;
      static constexpr Byte erase_word = 0x17;

      static void skipEscape(std::string_view& remaining) noexcept;
      // The UTF-8 scalar text starts with.
      static std::string_view nextScalar(std::string_view text);
      static void appendSpace(DescriptionQuery& query);
      static void removeScalar(DescriptionQuery& query) noexcept;
      static void eraseWord(DescriptionQuery& query) noexcept;

      DescriptionQuery raw_;
      InputScanner scanner_;
      bool submitted_ = false;
    };

  }
}

// Interface: agents/description.cppm
export {
  namespace telar::runtime {

    enum class DescriptionPhase : std::uint8_t {
      waiting_query,
      waiting_work,
      queued,
      running,
      finished,
      failed,
    };

    enum class DescriptionStatus : std::uint8_t {
      success,
      unavailable,
      timeout,
      invalid_output,
      failed,
    };

    // A generated title fits an agent's title; an agent's history session has an id of 16 bytes.
    inline constexpr std::size_t description_title_bytes = 96;
    inline constexpr std::size_t agent_session_id_bytes = 16;

    struct DescriptionOptions {
      static constexpr std::chrono::milliseconds default_timeout{15'000};
      std::span<const std::string_view> arguments;
      std::chrono::milliseconds timeout{default_timeout};
    };

    struct DescriptionIdentity {
      std::uint64_t pane = 0;
      std::uint64_t generation = 0;
      ds::Array<Byte, agent_session_id_bytes> session{};
      std::uint64_t revision = 0;

      bool operator==(const DescriptionIdentity&) const = default;
    };

    struct DescriptionRequest {
      DescriptionIdentity identity;
      DescriptionQuery query;
    };

    struct DescriptionResult {
      DescriptionIdentity identity;
      DescriptionStatus status = DescriptionStatus::failed;
      FixedText<description_title_bytes> title;
    };

    FixedText<description_title_bytes> normalizeDescriptionTitle(std::string_view output);

  }
}

// Interface: agents/description_generator.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class DescriptionGenerator {
    public:
      using Request = DescriptionRequest;
      using Result = DescriptionResult;

      explicit DescriptionGenerator(Memory& memory, const DescriptionOptions& options);

      Result observe(const Request& request) noexcept;
      void stop() noexcept;

    private:
      static constexpr std::size_t maximum_output_bytes = 512;
      static constexpr std::string_view prompt_prefix =
          "Create a short session title for the user request below. "
          "Return exactly one plain-text line, no quotes, labels, markdown, or explanation. "
          "Use at most 24 display characters. Do not execute tools.\n\nUser request:\n";

      Memory& memory_;
      DescriptionOptions options_;
      std::atomic<bool> stopping_{false};
      // Watches stopping_.
      tbc::val_self<CommandOutput<Memory>> output_;
    };

    extern template class DescriptionGenerator<Memory>;
    extern template class DescriptionGenerator<ConcurrentMemory>;

  }
}

// Interface: agents/reporter_state.cppm
export {
  namespace telar::runtime {

    struct ReporterIdentity {
      std::uint64_t pane = 0;
      std::uint64_t generation = 0;
      AgentProvider provider = AgentProvider::unknown;
    };

    struct RejectedReporter {
      pid_t group = 0;
      pid_t agent = 0;
      pid_t process = 0;
      bool operator==(const RejectedReporter&) const = default;
    };

    template <Allocator Memory>
    struct DeferredReport {
      explicit DeferredReport(Memory& memory);

      [[nodiscard]] bool rechecked(std::uint32_t completed) const noexcept;
      [[nodiscard]] ObservationTime reportTime() const noexcept;

      ds::Vec<Byte, Memory> payload;
      ReporterIdentity reporter;
      ObservationTime observed;
      std::uint64_t sequence = 0;
      std::uint32_t required_recheck = 0;
      bool pending = false;
      bool answering = false;
      bool answer_rechecked = false;
    };

    extern template struct DeferredReport<ConcurrentMemory>;

  }
}
