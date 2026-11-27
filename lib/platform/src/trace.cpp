#if TELAR_DEBUG

// Outside the module: the sink imports telar.platform.fs and .thread, which import
// telar.platform.primitives, whose interface declares these functions in the global module.
import std;
import telar.base.ds;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.platform.thread;
import telar.sys.posix;
import telar.sys.process;
import telar.tbc;

namespace telar::runtime::trace {
  namespace {

    struct [[tbc::shared]] Sink {
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

    // Never destroyed: a writer thread still running at exit keeps using it.
    Sink& traceSink() noexcept {
      [[clang::no_destroy]] static Sink sink;

      return sink;
    }

    constexpr std::size_t maximum_trace_bytes = std::size_t{256} * 1024 * 1024;
    constexpr long long nanoseconds_per_microsecond = 1000;

    bool writeAll(std::string_view bytes) noexcept {
      auto& sink = traceSink();

      while (!bytes.empty()) {
        const auto count = ::write(sink.file.get(), bytes.data(), bytes.size());
        if (count < 0 && sys::lastError() == EINTR) {
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

    // The record's line, as long as it fits in `buffer` with a byte to spare; empty when it does
    // not, as a line cut short would break the JSON.
    tbc::val_a<std::string_view> formatRecord(tbc::val_a<std::span<char>> buffer, const Record& entry, std::int64_t origin) noexcept {
      const auto start = static_cast<long long>(entry.start - origin);
      const auto duration = static_cast<long long>(entry.duration);

      try {
        const auto length = std::format_to_n(buffer.data(), static_cast<std::ptrdiff_t>(buffer.size()), "{{\"name\":\"{}\",\"ph\":\"X\",\"pid\":{},\"tid\":{},\"ts\":{}.{:03},\"dur\":{}.{:03}}},\n", entry.name, ::getpid(), entry.thread, start / nanoseconds_per_microsecond, start % nanoseconds_per_microsecond, duration / nanoseconds_per_microsecond, duration % nanoseconds_per_microsecond).size;

        return std::cmp_less(length, buffer.size()) ? std::string_view{buffer.data(), static_cast<std::size_t>(length)} : std::string_view{};
      } catch (const std::exception&) {
        return {};
      }
    }

    void format(std::span<const Record> records) noexcept {
      constexpr std::size_t record_bytes = 1024;
      auto& sink = traceSink();
      ds::Array<char, record_bytes> buffer{};

      for (const auto& entry : records) {
        if (sink.written > maximum_trace_bytes - buffer.size()) {
          sink.enabled = false;
          return;
        }

        const auto line = formatRecord(buffer.viewMut(), entry, sink.origin);
        if (!line.empty() && !writeAll(line)) {
          return;
        }
      }
    }

    // The closing metadata event and the end of the JSON array.
    void writeFooter(std::uint64_t dropped) noexcept {
      constexpr std::size_t footer_bytes = 256;
      ds::Array<char, footer_bytes> footer{};

      try {
        const auto* const end = std::format_to_n(footer.dataMut(), footer.size(), "{{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":{},\"args\":{{\"name\":\"telar-runtime\",\"dropped_records\":{}}}}}\n]\n", ::getpid(), dropped).out;

        writeAll({footer.data(), static_cast<std::size_t>(end - footer.data())});
      } catch (const std::exception&) {
        traceSink().enabled = false;
      }
    }

    void* run(void* /*context*/) noexcept {
      auto& sink = traceSink();

      setThreadName("telar.trace");
      std::unique_lock lock{sink.mutex};

      while (true) {
        sink.wake.wait_for(lock, std::chrono::seconds{1}, [&sink] {
          return sink.stopping || sink.count == sink.pending.size();
        });

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

  void record(const char* name, std::int64_t start, std::int64_t end) noexcept {
    auto& sink = traceSink();
    if (!sink.enabled.load(std::memory_order_relaxed)) {
      return;
    }

    const std::scoped_lock lock{sink.mutex};

    if (!sink.enabled.load(std::memory_order_relaxed)) {
      return;
    }

    if (sink.count == sink.pending.size()) {
      ++sink.dropped;
      return;
    }

    sink.pending[sink.count++] = {.name = name, .start = start, .duration = end - start, .thread = currentThreadId()};
    if (sink.count == sink.pending.size()) {
      sink.wake.notify_one();
    }
  }

  void open(const char* path, std::span<Record> first, std::span<Record> second) {
    constexpr mode_t private_file_mode = 0600;
    auto& sink = traceSink();
    const std::string_view full_path{path};
    // The tail of the terminated path, so terminated too.
    const auto name = full_path.substr(full_path.rfind('/') + 1);
    auto parent = openPrivateParent(path);
    FileDescriptor file{::openat(parent.get(), name.data(), combineFlags(O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW, O_CLOEXEC), private_file_mode)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
    if (!file) {
      throw SystemError{"Create trace file", sys::lastError()};
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
    auto& sink = traceSink();

    {
      const std::scoped_lock lock{sink.mutex};

      sink.enabled = false;
      sink.stopping = true;
    }

    sink.wake.notify_one();
    pthread_join(sink.writer, nullptr);
    writeFooter(sink.dropped);
    sink.file.reset();
  }

}
#endif
