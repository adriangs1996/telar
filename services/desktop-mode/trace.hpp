#pragma once

// TELAR_TRACE("component.function") times the rest of its scope. In builds with TELAR_DEBUG the
// session writes every timed scope to a Chrome trace next to its log; open it in
// https://ui.perfetto.dev. In release builds the macro expands to nothing and its argument is
// never evaluated.
//
// A name must be a string literal: records keep its pointer, so a trace never holds content.
#if TELAR_DEBUG
#include <chrono>
#include <cstdint>
#include <cstdio>

namespace trace {
  // Rejects at compile time anything a JSON string would need to escape.
  consteval const char *literal(const char *name) {
    for (const char *character = name; *character; ++character) {
      if (*character == '"' || *character == '\\' ||
          static_cast<unsigned char>(*character) < 0x20) {
        throw "trace names cannot contain quotes, backslashes or control characters";
      }
    }

    return name;
  }

  inline std::int64_t now() noexcept {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
  }

  void record(const char *name, std::int64_t start, std::int64_t end) noexcept;

  class Scope final {
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

  // Call from the main thread. Takes ownership of an open file; close writes the remaining
  // records and closes it.
  void open(std::FILE *file);
  void close();
} // namespace trace

#define TELAR_TRACE_JOIN_(left, right) left##right
#define TELAR_TRACE_JOIN(left, right) TELAR_TRACE_JOIN_(left, right)
#define TELAR_TRACE(name)                                                                          \
  const ::trace::Scope TELAR_TRACE_JOIN(telar_trace_, __LINE__) {                                  \
    ::trace::literal(name)                                                                         \
  }
#else
#define TELAR_TRACE(name) static_cast<void>(0)
#endif
