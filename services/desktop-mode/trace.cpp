#include "trace.hpp"

#if TELAR_DEBUG
#include <QByteArray>
#include <QThread>
#include <atomic>
#include <charconv>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>

namespace {
  // A writer thread formats and writes the records, so a traced thread only appends one. It
  // writes when a batch fills up and at least once a second.
  constexpr std::size_t batch_records = 16 * 1024;
  // Records beyond this, while the writer is behind, are dropped instead of growing memory.
  constexpr std::size_t maximum_buffered_records = 16 * batch_records;
  constexpr auto flush_interval = std::chrono::seconds{1};
  constexpr std::size_t maximum_trace_bytes = 256 * 1024 * 1024;

  struct Record {
    const char *name;
    std::int64_t start;
    std::int64_t duration;
    std::uint32_t thread;
  };

  struct Thread {
    std::uint32_t index;
    std::string name;
  };

  struct Sink {
    std::mutex mutex;
    std::condition_variable_any wake;
    std::atomic<bool> enabled = false;
    std::vector<Record> records;
    std::vector<Thread> threads;
    std::uint32_t thread_count = 0;
    std::uint64_t dropped = 0;
    // Only the writer, or close after it has stopped, touches these.
    std::FILE *file = nullptr;
    std::size_t written = 0;
    std::int64_t origin = 0;
    std::thread::id main_thread;
    std::jthread writer;
  };

  Sink sink;
  thread_local std::uint32_t thread_index = 0;

  void append(std::string &output, std::int64_t value) {
    char digits[24];
    const auto result = std::to_chars(digits, digits + sizeof(digits), value);
    output.append(digits, result.ptr);
  }

  // Trace times are microseconds; nanoseconds keep their precision as three decimals.
  void appendMicroseconds(std::string &output, std::int64_t nanoseconds) {
    append(output, nanoseconds / 1000);
    const auto fraction = nanoseconds % 1000;
    output += '.';
    output += static_cast<char>('0' + fraction / 100);
    output += static_cast<char>('0' + fraction / 10 % 10);
    output += static_cast<char>('0' + fraction % 10);
  }

  // Perfetto names each thread track after this metadata event. Names come from Qt and the
  // desktop, but are still kept to characters a JSON string holds as they are.
  std::string currentThreadName(std::uint32_t index) {
    std::string name = QThread::currentThread()->objectName().toStdString();
    if (std::this_thread::get_id() == sink.main_thread) {
      name = "main";
    } else if (name.empty()) {
      name = "thread " + std::to_string(index);
    }

    for (auto &character : name) {
      if (character == '"' || character == '\\' || static_cast<unsigned char>(character) < 0x20) {
        character = '_';
      }
    }

    return name;
  }

  void write(const std::string &bytes) {
    if (!sink.file || bytes.empty()) {
      return;
    }

    if (sink.written + bytes.size() > maximum_trace_bytes) {
      std::fclose(sink.file);
      sink.file = nullptr;
      sink.enabled = false;
      return;
    }

    std::fwrite(bytes.data(), 1, bytes.size(), sink.file);
    std::fflush(sink.file);
    sink.written += bytes.size();
  }

  void format(const std::vector<Thread> &threads, const std::vector<Record> &records) {
    std::string bytes;
    bytes.reserve(records.size() * 96);
    const auto pid = ::getpid();

    for (const auto &thread : threads) {
      bytes += R"({"name":"thread_name","ph":"M","pid":)";
      append(bytes, pid);
      bytes += R"(,"tid":)";
      append(bytes, thread.index);
      bytes += R"(,"args":{"name":")";
      bytes += thread.name;
      bytes += "\"}},\n";
    }

    for (const auto &record : records) {
      bytes += R"({"name":")";
      bytes += record.name;
      bytes += R"(","ph":"X","pid":)";
      append(bytes, pid);
      bytes += R"(,"tid":)";
      append(bytes, record.thread);
      bytes += R"(,"ts":)";
      appendMicroseconds(bytes, record.start - sink.origin);
      bytes += R"(,"dur":)";
      appendMicroseconds(bytes, record.duration);
      bytes += "},\n";
    }

    write(bytes);
  }

  void drain(std::unique_lock<std::mutex> &lock) {
    std::vector<Record> records;
    std::vector<Thread> threads;
    records.reserve(batch_records);
    std::swap(records, sink.records);
    std::swap(threads, sink.threads);
    lock.unlock();
    format(threads, records);
    lock.lock();
  }

  void run(std::stop_token stop) {
    std::unique_lock lock(sink.mutex);
    while (!stop.stop_requested()) {
      sink.wake.wait_for(lock, stop, flush_interval, [] {
        return sink.records.size() >= batch_records;
      });

      drain(lock);
    }
  }
} // namespace

void trace::record(const char *name, std::int64_t start, std::int64_t end) noexcept {
  if (!sink.enabled.load(std::memory_order_relaxed)) {
    return;
  }

  try {
    std::lock_guard lock(sink.mutex);
    if (thread_index == 0) {
      thread_index = ++sink.thread_count;
      sink.threads.push_back({thread_index, currentThreadName(thread_index)});
    }

    if (sink.records.size() >= maximum_buffered_records) {
      ++sink.dropped;
      return;
    }

    sink.records.push_back({name, start, end - start, thread_index});
    if (sink.records.size() == batch_records) {
      sink.wake.notify_one();
    }
  } catch (...) {
    // Tracing never takes the desktop down: a record that cannot be kept is dropped.
  }
}

void trace::open(std::FILE *file) {
  if (!file) {
    return;
  }

  sink.file = file;
  sink.main_thread = std::this_thread::get_id();
  sink.origin = now();
  sink.records.reserve(batch_records);
  // The array stays open until close: Perfetto reads a trace without its closing bracket, so a
  // crash still leaves a readable file.
  write("[\n");
  sink.writer = std::jthread(run);
  sink.enabled = sink.file != nullptr;
}

void trace::close() {
  sink.enabled = false;
  if (!sink.writer.joinable()) {
    return;
  }

  sink.writer.request_stop();
  sink.writer.join();
  std::unique_lock lock(sink.mutex);
  drain(lock);
  if (!sink.file) {
    return;
  }

  std::string footer = R"({"name":"process_name","ph":"M","pid":)";
  append(footer, ::getpid());
  footer += R"(,"args":{"name":"telar-desktop","dropped_records":)";
  append(footer, static_cast<std::int64_t>(sink.dropped));
  footer += "}}\n]\n";
  write(footer);
  std::fclose(sink.file);
  sink.file = nullptr;
}
#endif
