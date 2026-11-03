#include "trace.hpp"
#include "../platform/thread_name.hpp"

#if TELAR_DEBUG
#include "../platform/thread_identity.hpp"
#include "telar_platform/private_directory.hpp"
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <pthread.h>

namespace telar::runtime::trace {
namespace {

struct Sink {
  std::mutex mutex;
  std::condition_variable wake;
  std::atomic<bool> enabled{false};
  std::span<Record> pending;
  std::span<Record> draining;
  std::size_t count = 0;
  std::uint64_t dropped = 0;
  std::size_t written = 0;
  std::int64_t origin = 0;
  FileDescriptor file;
  pthread_t writer{};
  bool stopping = false;
};

Sink sink;
constexpr std::size_t maximum_trace_bytes = 256 * 1024 * 1024;

bool writeAll(std::string_view bytes) noexcept {
  while (!bytes.empty()) {
    const auto count = ::write(sink.file.get(), bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count <= 0) {
      sink.enabled = false;
      return false;
    }

    bytes.remove_prefix(static_cast<std::size_t>(count));
    sink.written += static_cast<std::size_t>(count);
  }

  return true;
}

void format(std::span<const Record> records) noexcept {
  std::array<char, 1024> buffer;
  for (const auto &entry : records) {
    if (sink.written > maximum_trace_bytes - buffer.size()) {
      sink.enabled = false;
      return;
    }

    const auto start = static_cast<long long>(entry.start - sink.origin);
    const auto duration = static_cast<long long>(entry.duration);
    const int length = std::snprintf(buffer.data(), buffer.size(), "{\"name\":\"%s\",\"ph\":\"X\",\"pid\":%d,\"tid\":%llu,\"ts\":%lld.%03lld,\"dur\":%lld.%03lld},\n", entry.name, ::getpid(), static_cast<unsigned long long>(entry.thread), start / 1000, start % 1000, duration / 1000, duration % 1000);
    if (length > 0 && static_cast<std::size_t>(length) < buffer.size()) {
      if (!writeAll({buffer.data(), static_cast<std::size_t>(length)})) {
        return;
      }
    }
  }
}

void *run(void *) noexcept {
  setThreadName("telar.trace");
  std::unique_lock lock{sink.mutex};
  while (true) {
    sink.wake.wait_for(lock, std::chrono::seconds{1}, [] { return sink.stopping || sink.count == sink.pending.size(); });
    const auto count = std::exchange(sink.count, 0);
    std::swap(sink.pending, sink.draining);
    const bool stopping = sink.stopping;
    lock.unlock();
    format(sink.draining.first(count));
    lock.lock();

    if (stopping) {
      return nullptr;
    }
  }
}

}

void record(const char *name, std::int64_t start, std::int64_t end) noexcept {
  if (!sink.enabled.load(std::memory_order_relaxed)) {
    return;
  }

  std::lock_guard lock{sink.mutex};
  if (!sink.enabled.load(std::memory_order_relaxed)) {
    return;
  }

  if (sink.count == sink.pending.size()) {
    ++sink.dropped;
    return;
  }

  sink.pending[sink.count++] = {name, start, end - start, currentThreadId()};
  if (sink.count == sink.pending.size()) {
    sink.wake.notify_one();
  }
}

void open(const char *path, std::span<Record> first, std::span<Record> second) {
  auto parent = openPrivateParent(path);
  FileDescriptor file{::openat(parent.get(), std::strrchr(path, '/') + 1, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600)};
  if (!file) {
    throw SystemError{"Create trace file", errno};
  }

  sink.file = std::move(file);
  sink.pending = first;
  sink.draining = second;
  sink.count = 0;
  sink.dropped = 0;
  sink.written = 0;
  sink.stopping = false;
  sink.origin = now();
  writeAll("[\n");
  const int result = pthread_create(&sink.writer, nullptr, run, nullptr);
  if (result != 0) {
    sink.file.reset();
    throw SystemError{"Start trace writer", result};
  }

  sink.enabled = true;
}

void close() noexcept {
  {
    std::lock_guard lock{sink.mutex};
    sink.enabled = false;
    sink.stopping = true;
  }

  sink.wake.notify_one();
  pthread_join(sink.writer, nullptr);
  std::array<char, 256> footer;
  const int length = std::snprintf(footer.data(), footer.size(), "{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":%d,\"args\":{\"name\":\"telar-runtime\",\"dropped_records\":%llu}}\n]\n", ::getpid(), static_cast<unsigned long long>(sink.dropped));
  writeAll({footer.data(), static_cast<std::size_t>(length)});
  sink.file.reset();
}

}
#endif
