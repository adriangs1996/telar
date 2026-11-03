#pragma once

#if TELAR_DEBUG
#include "telar_base/memory/allocator.hpp"
#include <chrono>
#include <cstdint>
#include <span>

namespace telar::runtime::trace {

struct Record {
  const char *name;
  std::int64_t start;
  std::int64_t duration;
  std::uint64_t thread;
};

inline constexpr std::size_t buffer_capacity = 16 * 1024;

consteval const char *literal(const char *name) {
  for (const char *character = name; *character; ++character) {
    if (*character == '"' || *character == '\\' || static_cast<unsigned char>(*character) < 0x20) {
      throw "Trace names must be JSON-safe literals";
    }
  }

  return name;
}

inline std::int64_t now() noexcept {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

void record(const char *name, std::int64_t start, std::int64_t end) noexcept;
void open(const char *path, std::span<Record> first, std::span<Record> second);
void close() noexcept;

class Scope {
public:
  explicit Scope(const char *name) noexcept
      : name_(name),
        start_(now()) {}

  ~Scope() {
    record(name_, start_, now());
  }

  Scope(const Scope &) = delete;
  Scope &operator=(const Scope &) = delete;

private:
  const char *name_;
  std::int64_t start_;
};

template <Allocator Memory>
class Session {
public:
  explicit Session(Memory &memory, const char *path)
      : buffers_(AllocatorRef<Record, Memory>{memory}) {
    if (path == nullptr) {
      return;
    }

    buffers_.resize(2 * buffer_capacity);
    open(path, std::span{buffers_}.first(buffer_capacity), std::span{buffers_}.subspan(buffer_capacity));
    active_ = true;
  }

  ~Session() {
    if (active_) {
      close();
    }
  }

  Session(const Session &) = delete;
  Session &operator=(const Session &) = delete;

private:
  Vector<Record, Memory> buffers_;
  bool active_ = false;
};

template <Allocator Memory>
Session(Memory &memory, const char *path) -> Session<Memory>;

}

#define TELAR_TRACE_JOIN_(left, right) left##right
#define TELAR_TRACE_JOIN(left, right) TELAR_TRACE_JOIN_(left, right)
#define TELAR_TRACE(name)                                                         \
  const ::telar::runtime::trace::Scope TELAR_TRACE_JOIN(telar_trace_, __LINE__) { \
    ::telar::runtime::trace::literal(name)                                        \
  }
#else
#define TELAR_TRACE(name) static_cast<void>(0)
#endif
