#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

namespace telar::runtime::phase_trace {

struct Record {
  const char *name = nullptr;
  std::uint64_t begin = 0;
  std::uint64_t end = 0;
  std::uint64_t thread = 0;
  std::uintptr_t object = 0;
  std::uint64_t work = 0;
  std::uint64_t kind = 0;
};

inline constexpr std::size_t capacity = 262144;

struct Buffer {
  std::array<Record, capacity> records;
  std::atomic<std::uint64_t> count{0};
  const char *prefix = std::getenv("TELAR_RUNTIME_PHASE_TRACE");

  ~Buffer() {
    const auto total = count.load(std::memory_order_relaxed);
    if (prefix == nullptr || total == 0) {
      return;
    }

    std::array<char, PATH_MAX> path{};
    const auto length = std::snprintf(path.data(), path.size(), "%s.%d.jsonl", prefix, getpid());
    if (length <= 0 || static_cast<std::size_t>(length) >= path.size()) {
      std::_Exit(75);
    }

    const int descriptor = ::open(path.data(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    FILE *output = descriptor >= 0 ? ::fdopen(descriptor, "w") : nullptr;
    if (output == nullptr) {
      std::_Exit(75);
    }

    const auto retained = total < capacity ? total : capacity;
    bool valid = std::fprintf(output, "{\"pid\":%d,\"clock\":\"CLOCK_UPTIME_RAW ns\",\"capacity\":%zu,\"count\":%llu,\"dropped\":%llu}\n", getpid(), capacity, static_cast<unsigned long long>(total), static_cast<unsigned long long>(total - retained)) > 0;
    for (std::size_t index = 0; index < retained; ++index) {
      const auto &r = records[index];
      if (r.name == nullptr || r.end < r.begin || r.thread == 0) {
        std::_Exit(75);
      }

      valid = std::fprintf(output, "{\"name\":\"%s\",\"begin_ns\":%llu,\"end_ns\":%llu,\"thread\":%llu,\"object\":%llu,\"work\":%llu,\"kind\":%llu}\n", r.name, static_cast<unsigned long long>(r.begin), static_cast<unsigned long long>(r.end), static_cast<unsigned long long>(r.thread), static_cast<unsigned long long>(r.object), static_cast<unsigned long long>(r.work), static_cast<unsigned long long>(r.kind)) > 0 && valid;
    }

    const int closed = std::fclose(output);
    if (!valid || closed != 0) {
      std::_Exit(75);
    }
  }
};

inline Buffer buffer;

inline std::uint64_t threadIdentity() {
  static thread_local const std::uint64_t identity = [] {
    std::uint64_t value = 0;
    if (pthread_threadid_np(nullptr, &value) != 0) {
      std::_Exit(75);
    }

    return value;
  }();
  return identity;
}

class Scope {
public:
  explicit Scope(const char *name, const void *object = nullptr, std::uint64_t work = 0, std::uint64_t kind = 0) noexcept
      : record_{name, 0, 0, 0, reinterpret_cast<std::uintptr_t>(object), work, kind} {
    if (buffer.prefix != nullptr) {
      record_.thread = threadIdentity();
      record_.begin = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    }
  }

  ~Scope() {
    if (record_.thread == 0) {
      return;
    }

    record_.end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    const auto index = buffer.count.fetch_add(1, std::memory_order_relaxed);
    if (index < capacity) {
      buffer.records[index] = record_;
    }
  }

  Scope(const Scope &) = delete;
  Scope &operator=(const Scope &) = delete;

private:
  Record record_;
};

}

#define TELAR_PHASE_JOIN_(a, b) a##b
#define TELAR_PHASE_JOIN(a, b) TELAR_PHASE_JOIN_(a, b)
#define TELAR_TRACE(name) const ::telar::runtime::phase_trace::Scope TELAR_PHASE_JOIN(phase_scope_, __LINE__){name}
#define TELAR_PHASE_TRACE(name, object, work, kind) const ::telar::runtime::phase_trace::Scope TELAR_PHASE_JOIN(phase_scope_, __LINE__){name, object, work, kind}
