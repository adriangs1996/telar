module;

#include <cstdint>
#include <string_view>


#include "telar_client/serializers/telar_protocol.hpp"
#include <chrono>
#include <concepts>
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <array>


#include "../diagnostics/timing.hpp"
#include <atomic>
#include <exception>
#include <cstddef>
#include "telar_base/diagnostics/config.hpp"


#include <cstring>
#include <sqlite3.h>
#include <stdexcept>

export module telar.runtime.history.event;

export import telar.runtime.command_capture.tracker;


export import telar.runtime.transport.connection;


export import telar.runtime.diagnostics.operation;

// Interface: history/launch_failure.cppm
export {
namespace telar::runtime {

enum class LaunchPhase : std::uint8_t {
  pane_registration,
  wait_actor,
  output_actor
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
  launch_failed
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
  inline explicit HistoryEvent(Memory &memory, const HistoryEventView &event)
      : event_(event),
        workspace_(event.session.workspace_path, AllocatorRef<char, Memory>{memory}),
        shell_(event.session.shell, AllocatorRef<char, Memory>{memory}),
        command_(event.command.command, AllocatorRef<char, Memory>{memory}),
        directory_(event.command.directory, AllocatorRef<char, Memory>{memory}),
        output_(event.command.output.begin(), event.command.output.end(), AllocatorRef<Byte, Memory>{memory}),
        cause_(event.failure.cause, AllocatorRef<char, Memory>{memory}) {}

  inline HistoryEventView view() const noexcept {
    auto result = event_;
    result.session.workspace_path = workspace_;
    result.session.shell = shell_;
    result.command.command = command_;
    result.command.directory = directory_;
    result.command.output = output_;
    result.failure.cause = cause_;
    return result;
  }

private:
  HistoryEventView event_;
  String<Memory> workspace_;
  String<Memory> shell_;
  String<Memory> command_;
  String<Memory> directory_;
  Vector<Byte, Memory> output_;
  String<Memory> cause_;
};

template <typename Sink>
concept HistoryEventSink = requires(Sink &sink, const HistoryEventView &event) {
  { sink.recordHistory(event) } noexcept -> std::same_as<bool>;
};

struct DiscardedHistory {
  inline bool recordHistory(const HistoryEventView &) noexcept {
    return true;
  }
};

inline DiscardedHistory discarded_history;

}
}

// Interface: history/failure_reply.cppm
export {
namespace telar::runtime {

template <typename Message, Allocator Memory>
void replyHistoryFailure(const Message &request, EncodedReply<Memory> &reply, bool available) {
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

  template <typename Message>
  inline diagnostics::OperationCounters *operation() noexcept {
    if constexpr (std::same_as<Message, QueryHistory>) {
      return &queries;
    } else if constexpr (std::same_as<Message, ImportHistory> || std::same_as<Message, ReportAgentCommand>) {
      return &writes;
    } else {
      return nullptr;
    }
  }

  inline HistoryMetrics snapshot(bool available) const noexcept {
    return {.available = available, .writes = writes.snapshot(), .queries = queries.snapshot()};
  }
#endif
};

}
}

// Interface: history/query_order.cppm
export {
namespace telar::runtime {

struct HistoryQueryOrder {
  inline explicit HistoryQueryOrder(const QueryHistory &query, bool persistent_client) noexcept
      : replaceable(persistent_client && query.offset == 0 && query.snapshot_id == 0 && query.entry_id == 0), distinct(query.distinct) {}

  inline bool supersededBy(const HistoryQueryOrder &newer) const noexcept {
    return replaceable && newer.replaceable && distinct == newer.distinct;
  }

  bool replaceable;
  bool distinct;
};

}
}

// Interface: history/sqlite_allocator.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory>
class SqliteAllocator {
public:
  inline explicit SqliteAllocator(Memory &memory) {
    if (active_ != nullptr || sqlite3_config(SQLITE_CONFIG_GETMALLOC, &previous_) != SQLITE_OK) {
      throw std::logic_error{"SQLite allocation must be configured before opening databases"};
    }

    sqlite3_mem_methods methods{
        &allocate,
        &deallocate,
        &reallocate,
        &allocationSize,
        &roundedSize,
        &initialize,
        &shutdown,
        &memory,
    };
    if (sqlite3_config(SQLITE_CONFIG_MALLOC, &methods) != SQLITE_OK) {
      throw std::logic_error{"Cannot install the SQLite allocator"};
    }

    if (sqlite3_initialize() != SQLITE_OK) {
      sqlite3_shutdown();
      sqlite3_config(SQLITE_CONFIG_MALLOC, &previous_);
      active_ = nullptr;
      throw std::bad_alloc{};
    }
  }

  inline ~SqliteAllocator() {
    sqlite3_shutdown();
    sqlite3_config(SQLITE_CONFIG_MALLOC, &previous_);
    active_ = nullptr;
  }

  SqliteAllocator(const SqliteAllocator &) = delete;
  SqliteAllocator &operator=(const SqliteAllocator &) = delete;

private:
  struct alignas(std::max_align_t) Header {
    int bytes;
  };

  inline static int initialize(void *context) noexcept {
    active_ = static_cast<Memory *>(context);
    return SQLITE_OK;
  }

  inline static void shutdown(void *) noexcept {}

  inline static void *allocate(int bytes) noexcept {
    if (bytes <= 0) {
      return nullptr;
    }

    auto *header = static_cast<Header *>(active_->allocate(sizeof(Header) + static_cast<std::size_t>(bytes), alignof(Header)));
    if (header == nullptr) {
      return nullptr;
    }

    header->bytes = bytes;
    return header + 1;
  }

  inline static void deallocate(void *pointer) noexcept {
    if (pointer == nullptr) {
      return;
    }

    auto *header = static_cast<Header *>(pointer) - 1;
    active_->deallocate(header, sizeof(Header) + static_cast<std::size_t>(header->bytes), alignof(Header));
  }

  inline static void *reallocate(void *pointer, int bytes) noexcept {
    if (bytes == 0) {
      deallocate(pointer);
      return nullptr;
    }

    void *replacement = allocate(bytes);
    if (replacement != nullptr && pointer != nullptr) {
      std::memcpy(replacement, pointer, static_cast<std::size_t>(std::min(allocationSize(pointer), bytes)));
      deallocate(pointer);
    }

    return replacement;
  }

  inline static int allocationSize(void *pointer) noexcept {
    return (static_cast<Header *>(pointer) - 1)->bytes;
  }

  inline static int roundedSize(int bytes) noexcept {
    constexpr int alignment = alignof(Header);
    if (bytes <= 0 || bytes > std::numeric_limits<int>::max() - alignment + 1) {
      return 0;
    }

    return (bytes + alignment - 1) & ~(alignment - 1);
  }

  inline static Memory *active_ = nullptr;
  sqlite3_mem_methods previous_{};
};

template <ConcurrentAllocator Memory>
SqliteAllocator(Memory &memory) -> SqliteAllocator<Memory>;

}
}
