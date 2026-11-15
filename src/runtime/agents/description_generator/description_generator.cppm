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

import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.platform.error;
import telar.runtime.platform.process_probe;
import telar.base.text;

// Interface: agents/description_capture.cppm
export {
  namespace telar::runtime {

    inline constexpr std::size_t description_query_capacity = 4096;
    using DescriptionQuery = SensitiveText<description_query_capacity>;

    class DescriptionCapture {
    public:
      ~DescriptionCapture();

      bool feed(std::span<const Byte> input);
      void clear() noexcept;
      DescriptionQuery normalized() const;

    private:
      static constexpr Byte clear_line = 0x15;
      static constexpr Byte erase_word = 0x17;

      static void skipEscape(std::string_view& remaining) noexcept;
      static std::string_view nextScalar(unsigned char byte, std::string_view remaining);
      static void appendSpace(DescriptionQuery& query);
      static void removeScalar(DescriptionQuery& query) noexcept;

      DescriptionQuery raw_;
      InputScanner scanner_;
      bool submitted_ = false;
    };

  }
}

// Interface: agents/description.cppm
export {
  namespace telar::runtime {

    enum class DescriptionPhase {
      waiting_query,
      waiting_work,
      queued,
      running,
      finished,
      failed,
    };

    enum class DescriptionStatus {
      success,
      unavailable,
      timeout,
      invalid_output,
      failed,
    };

    struct DescriptionOptions {
      std::span<const std::string_view> arguments;
      std::chrono::milliseconds timeout{15'000};
    };

    struct DescriptionIdentity {
      std::uint64_t pane = 0;
      std::uint64_t generation = 0;
      std::array<Byte, 16> session{};
      std::uint64_t revision = 0;

      bool operator==(const DescriptionIdentity&) const = default;
    };

    struct DescriptionRequest {
      DescriptionIdentity identity;
      DescriptionQuery query{};
    };

    struct DescriptionResult {
      DescriptionIdentity identity;
      DescriptionStatus status = DescriptionStatus::failed;
      FixedText<96> title{};
    };

    FixedText<96> normalizeDescriptionTitle(std::string_view output);

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
      tbc::view<CommandOutput<Memory>, tbc::lt::self> output_;
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

      bool rechecked(std::uint32_t completed) const noexcept;
      ObservationTime reportTime() const noexcept;

      Vector<Byte, Memory> payload;
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
