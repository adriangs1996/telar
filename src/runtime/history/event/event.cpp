module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.history.event;

import std;
import telar.native.sqlite;

namespace telar::runtime {

  HistoryEvent::HistoryEvent(ConcurrentMemory& memory, const HistoryEventView& event)
      : event_(event),
        workspace_(memory, event.session.workspace_path),
        shell_(memory, event.session.shell),
        command_(memory, event.command.command),
        directory_(memory, event.command.directory),
        output_(memory),
        cause_(memory, event.failure.cause) {
    output_.extend(event.command.output);
  }

  HistoryEventView HistoryEvent::view() const noexcept {
    auto result = event_;

    result.session.workspace_path = workspace_;
    result.session.shell = shell_;
    result.command.command = command_;
    result.command.directory = directory_;
    result.command.output = output_;
    result.failure.cause = cause_;
    return result;
  }

  bool DiscardedHistory::recordHistory(const HistoryEventView& /*event*/) noexcept {
    return true;
  }

#if TELAR_DIAGNOSTICS
  HistoryMetrics HistoryCounters::snapshot(bool available) const noexcept {
    return {.available = available, .writes = writes.snapshot(), .queries = queries.snapshot()};
  }
#endif

  SqliteAllocator::SqliteAllocator(ConcurrentMemory& memory) {
    if (active_memory != nullptr || sqlite3_config(SQLITE_CONFIG_GETMALLOC, &previous_) != SQLITE_OK) { // NOLINT(cppcoreguidelines-pro-type-vararg): sqlite3_config's C signature is variadic
      throw std::logic_error{"SQLite allocation must be configured before opening databases"};
    }

    sqlite3_mem_methods methods{
        .xMalloc = &allocate,
        .xFree = &deallocate,
        .xRealloc = &reallocate,
        .xSize = &allocationSize,
        .xRoundup = &roundedSize,
        .xInit = &initialize,
        .xShutdown = &shutdown,
        .pAppData = &memory,
    };
    if (sqlite3_config(SQLITE_CONFIG_MALLOC, &methods) != SQLITE_OK) { // NOLINT(cppcoreguidelines-pro-type-vararg): sqlite3_config's C signature is variadic
      throw std::logic_error{"Cannot install the SQLite allocator"};
    }

    if (sqlite3_initialize() != SQLITE_OK) {
      sqlite3_shutdown();
      sqlite3_config(SQLITE_CONFIG_MALLOC, &previous_); // NOLINT(cppcoreguidelines-pro-type-vararg): sqlite3_config's C signature is variadic
      active_memory = nullptr;
      throw std::bad_alloc{};
    }
  }

  SqliteAllocator::~SqliteAllocator() {
    sqlite3_shutdown();
    sqlite3_config(SQLITE_CONFIG_MALLOC, &previous_); // NOLINT(cppcoreguidelines-pro-type-vararg): sqlite3_config's C signature is variadic
    active_memory = nullptr;
  }

  int SqliteAllocator::initialize(void* context) noexcept {
    active_memory = static_cast<ConcurrentMemory*>(context);
    return SQLITE_OK;
  }

  void SqliteAllocator::shutdown(void* /*context*/) noexcept {}

  void* SqliteAllocator::allocate(int bytes) noexcept {
    if (bytes <= 0) {
      return nullptr;
    }

    auto* header = static_cast<Header*>(active_memory->allocate(sizeof(Header) + static_cast<std::size_t>(bytes), alignof(Header)));
    if (header == nullptr) {
      return nullptr;
    }

    header->bytes = bytes;
    // SQLite gets the bytes after the header, and hands that pointer back to the hooks below.
#pragma clang unsafe_buffer_usage begin
    return header + 1;
#pragma clang unsafe_buffer_usage end
  }

  void SqliteAllocator::deallocate(void* pointer) noexcept {
    if (pointer == nullptr) {
      return;
    }

    // The header sits right before the bytes allocate handed SQLite.
#pragma clang unsafe_buffer_usage begin
    auto* header = static_cast<Header*>(pointer) - 1;
#pragma clang unsafe_buffer_usage end

    active_memory->deallocate(header, sizeof(Header) + static_cast<std::size_t>(header->bytes), alignof(Header));
  }

  void* SqliteAllocator::reallocate(void* pointer, int bytes) noexcept {
    if (bytes == 0) {
      deallocate(pointer);
      return nullptr;
    }

    void* replacement = allocate(bytes);
    if (replacement != nullptr && pointer != nullptr) {
      // Both blocks come from allocate, which sizes each by its header.
#pragma clang unsafe_buffer_usage begin
      std::memcpy(replacement, pointer, static_cast<std::size_t>(std::min(allocationSize(pointer), bytes)));
#pragma clang unsafe_buffer_usage end
      deallocate(pointer);
    }

    return replacement;
  }

  int SqliteAllocator::allocationSize(void* pointer) noexcept {
    // The header sits right before the bytes allocate handed SQLite.
#pragma clang unsafe_buffer_usage begin
    return (static_cast<Header*>(pointer) - 1)->bytes;
#pragma clang unsafe_buffer_usage end
  }

  int SqliteAllocator::roundedSize(int bytes) noexcept {
    constexpr int alignment = alignof(Header);
    if (bytes <= 0 || bytes > std::numeric_limits<int>::max() - alignment + 1) {
      return 0;
    }

    constexpr auto alignment_mask = ~static_cast<unsigned>(alignment - 1);

    return static_cast<int>(static_cast<unsigned>(bytes + alignment - 1) & alignment_mask);
  }

}
