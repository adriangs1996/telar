module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

#include <sqlite3.h>

export module telar.runtime.history.event;

import std;

export import telar.runtime.history.command;

export import telar.runtime.transport.connection;

export import telar.runtime.diagnostics.operation;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.history;
import telar.wire.runtime;
import telar.runtime.diagnostics.line;

// Interface: history/launch_failure.cppm
export {
  namespace telar::runtime {

    enum class LaunchPhase : std::uint8_t {
      pane_registration,
      wait_actor,
      output_actor,
    };

    struct LaunchFailure {
      std::uint64_t generation = 0;
      LaunchPhase phase = LaunchPhase::pane_registration;
      std::string_view cause;
    };

  }
}

// Interface: history/event.cppm
export {
  namespace telar::runtime {

    struct HistorySession {
      std::array<Byte, 16> id{};
      std::uint64_t pane = 0;
      TabLocation location{};
      std::int64_t started_at_ms = 0;
      std::string_view workspace_path;
      std::string_view shell;
    };

    enum class HistoryEventKind {
      session_started,
      command_finished,
      session_finished,
      session_title,
      launch_failed,
    };

    struct HistorySessionTitle {
      std::array<Byte, 16> session{};
      FixedText<96> title{};
      AgentTitleSource source = AgentTitleSource::telar;
      AgentTitleState state = AgentTitleState::failed;
    };

    struct HistoryEventView {
      HistoryEventKind kind;
      HistorySession session;
      CapturedCommand command{};
      std::int64_t finished_at_ms = 0;
      HistorySessionTitle title{};
      LaunchFailure failure{};
    };

    template <Allocator Memory>
    class HistoryEvent {
    public:
      explicit HistoryEvent(Memory& memory, const HistoryEventView& event);

      HistoryEventView view() const noexcept;

    private:
      HistoryEventView event_;
      String<Memory> workspace_;
      String<Memory> shell_;
      String<Memory> command_;
      String<Memory> directory_;
      Vector<Byte, Memory> output_;
      String<Memory> cause_;
    };

    extern template class HistoryEvent<ConcurrentMemory>;

    template <typename Sink>
    concept HistoryEventSink = requires(Sink& sink, const HistoryEventView& event) {
      { sink.recordHistory(event) } noexcept -> std::same_as<bool>;
    };

    struct DiscardedHistory {
      bool recordHistory(const HistoryEventView& event) noexcept;
    };

    inline DiscardedHistory discarded_history;

  }
}

// Interface: history/failure_reply.cppm
export {
  namespace telar::runtime {

    // Generic over the protocol's history messages and the reply's allocator, an open
    // set no implementation unit can instantiate ahead.
    template <typename Message, Allocator Memory>
    TBC_HOT_PATH void replyHistoryFailure(const Message& request, EncodedReply<Memory>& reply, bool available) {
      if constexpr (std::same_as<Message, ImportHistory> || std::same_as<Message, ReportAgentCommand>) {
        reply.send(RequestCompleted{.request_id = request.request_id});
      } else if constexpr (std::same_as<Message, DeleteHistory> || std::same_as<Message, PruneHistory>) {
        reply.send(HistoryPruned{.request_id = request.request_id, .removed = 0});
      } else {
        std::string_view message = "history database is unavailable";

        if (available) {
          if constexpr (std::same_as<Message, QueryHistory>) {
            message = "history query failed";
          } else if constexpr (std::same_as<Message, ReadHistoryOutput>) {
            message = "history output read failed";
          } else {
            message = "history stats failed";
          }
        }

        reply.send(RequestFailed{.request_id = request.request_id, .code = FailureCode::internal, .message = message});
      }
    }

  }
}

// Interface: history/metrics.cppm
export {
  namespace telar::runtime {

    struct HistoryMetrics {
      bool available = false;
      diagnostics::OperationSnapshot writes{};
      diagnostics::OperationSnapshot queries{};
      diagnostics::RequestQueueSnapshot queue{};
      std::uint64_t query_submissions = 0;
      std::uint64_t query_refusals = 0;
      std::uint64_t sqlite_bytes = 0;
    };

    struct HistoryCounters {
#if TELAR_DIAGNOSTICS
      diagnostics::OperationCounters writes;
      diagnostics::OperationCounters queries;

      // Chosen at compile time from the message type, for every history request.
      template <typename Message>
      TBC_HOT_PATH inline diagnostics::OperationCounters* operation() noexcept {
        if constexpr (std::same_as<Message, QueryHistory>) {
          return &queries;
        } else if constexpr (std::same_as<Message, ImportHistory> || std::same_as<Message, ReportAgentCommand>) {
          return &writes;
        } else {
          return nullptr;
        }
      }

      HistoryMetrics snapshot(bool available) const noexcept;
#endif
    };

  }
}

// Interface: history/sqlite_allocator.cppm
export {
  namespace telar::runtime {

    template <ConcurrentAllocator Memory>
    class SqliteAllocator {
    public:
      explicit SqliteAllocator(Memory& memory);
      ~SqliteAllocator();

      SqliteAllocator(const SqliteAllocator&) = delete;
      SqliteAllocator& operator=(const SqliteAllocator&) = delete;

    private:
      struct alignas(std::max_align_t) Header {
        int bytes;
      };

      static int initialize(void* context) noexcept;
      static void shutdown(void*) noexcept;
      static void* allocate(int bytes) noexcept;
      static void deallocate(void* pointer) noexcept;
      static void* reallocate(void* pointer, int bytes) noexcept;
      static int allocationSize(void* pointer) noexcept;
      static int roundedSize(int bytes) noexcept;

      inline static Memory* active_ = nullptr;
      sqlite3_mem_methods previous_{};
    };

    template <ConcurrentAllocator Memory>
    SqliteAllocator(Memory& memory) -> SqliteAllocator<Memory>;

    extern template class SqliteAllocator<ConcurrentMemory>;

  }
}
