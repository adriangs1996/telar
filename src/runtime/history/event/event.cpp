module;
#include "telar_base/diagnostics/config.hpp"
#include <cstring>
#include <sqlite3.h>

module telar.runtime.history.event;

import std;

namespace telar::runtime {

  template <Allocator Memory>
  HistoryEvent<Memory>::HistoryEvent(Memory& memory, const HistoryEventView& event)
      : event_(event),
        workspace_(event.session.workspace_path, AllocatorRef<char, Memory>{memory}),
        shell_(event.session.shell, AllocatorRef<char, Memory>{memory}),
        command_(event.command.command, AllocatorRef<char, Memory>{memory}),
        directory_(event.command.directory, AllocatorRef<char, Memory>{memory}),
        output_(event.command.output.begin(), event.command.output.end(), AllocatorRef<Byte, Memory>{memory}),
        cause_(event.failure.cause, AllocatorRef<char, Memory>{memory}) {}

  template <Allocator Memory>
  HistoryEventView HistoryEvent<Memory>::view() const noexcept {
    auto result = event_;

    result.session.workspace_path = workspace_;
    result.session.shell = shell_;
    result.command.command = command_;
    result.command.directory = directory_;
    result.command.output = output_;
    result.failure.cause = cause_;
    return result;
  }

  template class HistoryEvent<ConcurrentMemory>;

  bool DiscardedHistory::recordHistory(const HistoryEventView&) noexcept {
    return true;
  }

#if TELAR_DIAGNOSTICS
  HistoryMetrics HistoryCounters::snapshot(bool available) const noexcept {
    return {.available = available, .writes = writes.snapshot(), .queries = queries.snapshot()};
  }
#endif

  template <ConcurrentAllocator Memory>
  SqliteAllocator<Memory>::SqliteAllocator(Memory& memory) {
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

  template <ConcurrentAllocator Memory>
  SqliteAllocator<Memory>::~SqliteAllocator() {
    sqlite3_shutdown();
    sqlite3_config(SQLITE_CONFIG_MALLOC, &previous_);
    active_ = nullptr;
  }

  template <ConcurrentAllocator Memory>
  int SqliteAllocator<Memory>::initialize(void* context) noexcept {
    active_ = static_cast<Memory*>(context);
    return SQLITE_OK;
  }

  template <ConcurrentAllocator Memory>
  void SqliteAllocator<Memory>::shutdown(void*) noexcept {}

  template <ConcurrentAllocator Memory>
  void* SqliteAllocator<Memory>::allocate(int bytes) noexcept {
    if (bytes <= 0) {
      return nullptr;
    }

    auto* header = static_cast<Header*>(active_->allocate(sizeof(Header) + static_cast<std::size_t>(bytes), alignof(Header)));
    if (header == nullptr) {
      return nullptr;
    }

    header->bytes = bytes;
    return header + 1;
  }

  template <ConcurrentAllocator Memory>
  void SqliteAllocator<Memory>::deallocate(void* pointer) noexcept {
    if (pointer == nullptr) {
      return;
    }

    auto* header = static_cast<Header*>(pointer) - 1;

    active_->deallocate(header, sizeof(Header) + static_cast<std::size_t>(header->bytes), alignof(Header));
  }

  template <ConcurrentAllocator Memory>
  void* SqliteAllocator<Memory>::reallocate(void* pointer, int bytes) noexcept {
    if (bytes == 0) {
      deallocate(pointer);
      return nullptr;
    }

    void* replacement = allocate(bytes);
    if (replacement != nullptr && pointer != nullptr) {
      std::memcpy(replacement, pointer, static_cast<std::size_t>(std::min(allocationSize(pointer), bytes)));
      deallocate(pointer);
    }

    return replacement;
  }

  template <ConcurrentAllocator Memory>
  int SqliteAllocator<Memory>::allocationSize(void* pointer) noexcept {
    return (static_cast<Header*>(pointer) - 1)->bytes;
  }

  template <ConcurrentAllocator Memory>
  int SqliteAllocator<Memory>::roundedSize(int bytes) noexcept {
    constexpr int alignment = alignof(Header);
    if (bytes <= 0 || bytes > std::numeric_limits<int>::max() - alignment + 1) {
      return 0;
    }

    return (bytes + alignment - 1) & ~(alignment - 1);
  }

  template class SqliteAllocator<ConcurrentMemory>;

}
