#include "check.hpp"
#include "diagnostics/file_storage.hpp"
#include "diagnostics/log_writer.hpp"
#include "diagnostics/proxy_sample.hpp"
#include "diagnostics/runtime_counters.hpp"
#include "diagnostics/runtime_telemetry.hpp"
#include "memory/allocator.hpp"
#include "platform/temporary_directory.hpp"
#include "terminal/frame_sync.hpp"
#include "terminal/terminal.hpp"
#include <filesystem>
#include <fstream>
#include <thread>

using namespace telar::runtime;
using namespace telar::runtime::diagnostics;

namespace {

std::string readFile(const std::filesystem::path &path) {
  std::ifstream stream{path};
  return {std::istreambuf_iterator<char>{stream}, std::istreambuf_iterator<char>{}};
}

void writeFile(const std::filesystem::path &path, std::string_view text = "fixture") {
  std::ofstream stream{path};
  stream << text;
  check(stream.good());
}

void testNames() {
  for (const auto name : {"a.sock.runtime-42.log", "a.sock.client-42.log.1", ".runtime-00042.log", "a.client-4294967295.log", "a.runtime-4__2.log"}) {
    const auto parsed = LogName::parse(name);
    check(parsed && parsed->process != 0);
  }

  for (const auto name : {"a.runtime.log", "a.runtime.start.log", "a.runtime-0.log", "a.runtime--1.log", "a.runtime-4294967296.log", "a.worker-42.log", "a.runtime-42.log.2", "a.runtime-42x.log", "a.runtime-.log", "a.runtime-_42.log", "a.runtime-42_.log"}) {
    check(!LogName::parse(name));
  }
}

void testRotation() {
  TemporaryDirectory directory{"/tmp/telar-diagnostics-XXXXXX"};
  const auto endpoint = std::string{directory.path()} + "/runtime.sock";
  LogSink sink{endpoint, ::getpid(), 8};
  check(sink.available());
  const std::string path{sink.path()};
  struct stat status;
  check(::stat(path.c_str(), &status) == 0 && (status.st_mode & 0777) == 0600);
  check(sink.write("first\n") && sink.write("second\n"));
  check(readFile(path + ".1") == "first\n" && readFile(path) == "second\n");
  check(sink.write("third\n"));
  check(readFile(path + ".1") == "second\n" && readFile(path) == "third\n");

  LogSink duplicate{endpoint};
  check(!duplicate.available() && readFile(path) == "third\n");
  check(sink.write("an oversized record\n"));
  check(readFile(path + ".1") == "third\n" && readFile(path) == "an oversized record\n");
  std::filesystem::remove(path + ".1");
  std::filesystem::create_directory(path + ".1");
  check(!sink.write("failed\n") && !sink.available());
  check(readFile(path) == "an oversized record\n");

  check(!LogSink{"relative.sock"}.available());
  check(!LogSink{std::string_view{"/tmp/hidden\0suffix", 18}}.available());
  check(!LogSink{endpoint, 0}.available());
}

void testOrphans() {
  TemporaryDirectory directory{"/tmp/telar-diagnostics-XXXXXX"};
  const std::filesystem::path root{directory.path()};
  const auto endpoint = (root / "custom").string();
  const auto active = "other.sock.client-" + std::to_string(::getpid()) + ".log";
  const std::array removed{"custom.runtime-4294967295.log", "other.sock.client-4294967295.log.1"};
  const std::array retained{"unrelated.runtime-4294967295.log", "custom.runtime.log", "custom.runtime.start.log", "custom.runtime-0.log", "custom.worker-4294967295.log"};
  for (const auto name : removed) {
    writeFile(root / name);
  }
  for (const auto name : retained) {
    writeFile(root / name);
  }
  writeFile(root / active);
  std::filesystem::create_symlink(root / active, root / "link.sock.runtime-4294967295.log");
  std::filesystem::create_directory(root / "directory.sock.runtime-4294967295.log");

  LogSink::removeOrphans(endpoint);
  for (const auto name : removed) {
    check(!std::filesystem::exists(root / name));
  }
  for (const auto name : retained) {
    check(readFile(root / name) == "fixture");
  }
  check(readFile(root / active) == "fixture");
  check(std::filesystem::is_symlink(root / "link.sock.runtime-4294967295.log"));
  check(std::filesystem::is_directory(root / "directory.sock.runtime-4294967295.log"));
}

void testLineAndTiming() {
  Timing timing;
  check(timing.average() == 0);
  timing.observe(2000);
  timing.observe(4000);
  check(timing.count == 2 && timing.average() == 3000 && timing.maximum_ns == 4000);
  Line line;
  line.reset();
  line.literal("role", "\"runtime\"");
  line.field("port", std::optional<std::uint64_t>{});
  line.timing("average", "maximum", timing);
  check(line.finish() == "{\"role\":\"runtime\",\"port\":null,\"average\":3,\"maximum\":4}\n");

  timing.total_ns = std::numeric_limits<std::uint64_t>::max() - 1;
  timing.count = std::numeric_limits<std::uint64_t>::max();
  timing.observe(9);
  check(timing.total_ns == std::numeric_limits<std::uint64_t>::max() && timing.count == std::numeric_limits<std::uint64_t>::max());
  bool overflowed = false;
  try {
    line.reset();
    line.literal("too_large", std::string(Line::capacity, '0'));
  } catch (const std::length_error &) {
    overflowed = true;
  }
  check(overflowed);
}

void testProxySample() {
  ProxyCounters counters;
  counters.record(ProxyCounter::tls_mint_failure, 7);
  counters.record(ProxyCounter::invalid_authorization_rejection, 3);
  const ProxyMetrics metrics{counters.snapshot(), 4, 2};
  Line line;
  line.reset();
  writeProxySample(line, metrics);
  writeCaptureSample(line, CaptureMetrics{.started = 8, .truncated = 2, .decode_failed = 1, .queued = 3});
  const auto contents = line.finish();
  check(contents.contains("\"proxy_tls_mint_failures\":7"));
  check(contents.contains("\"proxy_invalid_authorization_rejections\":3"));
  check(contents.contains("\"proxy_active_connections\":4"));
  check(contents.contains("\"proxy_connection_limit_drops\":2"));
  check(contents.contains("\"proxy_capture_started\":8"));
  check(contents.contains("\"proxy_capture_queue_depth\":3"));
}

void testFileStorage() {
  TemporaryDirectory directory{"/tmp/telar-storage-sample-XXXXXX"};
  const std::filesystem::path path = std::filesystem::path{directory.path()} / "history.db";
  SystemAllocator memory;
  FileStorage storage{memory, path.string()};
  const auto now = FileStorage<SystemAllocator>::Clock::now();
  writeFile(path, std::string(512, 'a'));
  storage.sample(now);
  check(storage.bytes() == 512);

  writeFile(path, std::string(1024, 'b'));
  storage.sample(now + std::chrono::milliseconds{500});
  check(storage.bytes() == 512);
  storage.sample(now + std::chrono::seconds{1});
  check(storage.bytes() == 1024);
  std::filesystem::remove(path);
  storage.sample(now + std::chrono::seconds{2});
  check(storage.bytes() == 0);

  const auto target = path.parent_path() / "target";
  writeFile(target, std::string(2048, 'c'));
  std::filesystem::create_symlink(target, path);
  storage.sample(now + std::chrono::seconds{3});
  check(storage.bytes() == 0);
  std::filesystem::remove(path);
  std::filesystem::create_directory(path);
  storage.sample(now + std::chrono::seconds{4});
  check(storage.bytes() == 0);

  FileStorage in_memory{memory, ":memory:"};
  in_memory.sample(now);
  check(in_memory.bytes() == 0);
}

void testAsyncWriter() {
  TemporaryDirectory directory{"/tmp/telar-diagnostics-XXXXXX"};
  const auto endpoint = std::string{directory.path()} + "/runtime.sock";
  const auto path = endpoint + ".runtime-" + std::to_string(::getpid()) + ".log";
  {
    LogSession session{endpoint};
    session.sample([](Line &) { throw std::bad_alloc{}; });
    for (unsigned index = 0; index != 100; ++index) {
      session.sample([&](Line &line) { line.field("sample", index); });
    }
  }

  const auto contents = readFile(path);
  check(contents.starts_with("{\"sample\":0}\n") && contents.ends_with("}\n"));
  std::size_t lines = 0;
  std::string_view remaining{contents};
  while (!remaining.empty()) {
    const auto end = remaining.find('\n');
    check(end != std::string_view::npos && remaining.substr(0, end).starts_with("{\"sample\":") && remaining[end - 1] == '}');
    remaining.remove_prefix(end + 1);
    ++lines;
  }
  check(lines >= 1 && lines <= 100);
}

#if TELAR_DIAGNOSTICS
void testFrameCounters() {
  SystemAllocator memory;
  Terminal terminal{memory, telar::TerminalSize{20, 4, 8, 16}};
  FrameSync frames{memory, 1};
  FrameCounters counters;
  frames.setCounters(counters);
  terminal.refresh();
  const auto snapshot = frames.prepare(terminal.screen);
  check(!snapshot.empty() && counters.frames == 1 && counters.snapshots == 1 && counters.frame_cells == 80);
  check(frames.acknowledge(1) && counters.ack.count == 1);
  constexpr std::array<telar::Byte, 1> input{'x'};
  terminal.feed(input);
  terminal.refresh();
  check(!frames.prepare(terminal.screen).empty() && counters.frames == 2 && counters.snapshots == 1);
  check(counters.frame_cells == 81 && counters.damaged_rows >= 1 && counters.diff_scanned_cells >= 20);
  check(counters.encode.count == 2 && frames.acknowledge(2));
  check(frames.prepare(terminal.screen).empty() && counters.frames == 2);
}

void testAllocationStatistics() {
  SystemAllocator system;
  BudgetAllocator budget{system, 1024};
  SynchronizedAllocator memory{budget};
  void *interactive = nullptr;
  {
    AllocationScope scope{AllocationPath::interactive};
    TerminalAllocationScope terminal;
    interactive = memory.allocate(128, 8);
  }
  check(interactive != nullptr);
  {
    AllocationScope scope{AllocationPath::media};
    auto *media = memory.allocate(64, 8);
    check(media != nullptr);
    memory.deallocate(media, 64, 8);
  }
  const auto statistics = memory.statistics();
  check(statistics.live_bytes == 128 && statistics.live_allocations == 1);
  check(statistics.total.count == 2 && statistics.total.bytes == 192);
  check(statistics.paths[static_cast<std::size_t>(AllocationPath::interactive)].bytes == 128);
  check(statistics.paths[static_cast<std::size_t>(AllocationPath::media)].bytes == 64);
  check(statistics.interactive_terminal.count == 1 && statistics.interactive_terminal.bytes == 128);
  memory.deallocate(interactive, 128, 8);

  std::atomic<bool> finished{false};
  std::thread worker{[&] {
    AllocationScope scope{AllocationPath::observation};
    for (unsigned index = 0; index != 1000; ++index) {
      auto *allocation = memory.allocate(16, 8);
      check(allocation != nullptr);
      memory.deallocate(allocation, 16, 8);
    }
    finished.store(true, std::memory_order_release);
  }};
  while (!finished.load(std::memory_order_acquire)) {
    const auto snapshot = memory.statistics();
    check(snapshot.live_bytes <= 16 && snapshot.live_allocations <= 1);
  }
  worker.join();
  check(memory.statistics().paths[static_cast<std::size_t>(AllocationPath::observation)].count == 1000);
  check(memory.statistics().live_bytes == 0 && memory.statistics().live_allocations == 0);
}

void testRuntimeSample() {
  TemporaryDirectory directory{"/tmp/telar-diagnostics-XXXXXX"};
  const auto endpoint = std::string{directory.path()} + "/runtime.sock";
  const auto path = endpoint + ".runtime-" + std::to_string(::getpid()) + ".log";
  SystemAllocator system;
  BudgetAllocator budget{system, 32 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  {
    RuntimeModel model{memory};
    model.metrics.panes.pty_bytes = 72;
    model.metrics.client_messages = 9;
    RuntimeTelemetry telemetry{endpoint, {}};
    telemetry.tick(model, memory, 0, 0, RuntimeTelemetry::Clock::now() + std::chrono::seconds{2});
  }

  const auto contents = readFile(path);
  check(contents.contains("\"role\":\"runtime\"") && contents.contains("\"pty_bytes\":72"));
  check(contents.contains("\"client_messages\":9") && contents.contains("\"heap_live_bytes\":"));
  check(contents.contains("\"proxy_port\":null") && contents.ends_with("}\n"));
  check(residentBytes() != 0 && budget.liveBytes() == 0);
}
#else
static_assert(std::is_empty_v<RuntimeTelemetry>);
static_assert(std::is_empty_v<RuntimeCounters>);
#endif

}

int main() {
  testNames();
  testRotation();
  testOrphans();
  testLineAndTiming();
  testProxySample();
  testFileStorage();
  testAsyncWriter();
#if TELAR_DIAGNOSTICS
  testFrameCounters();
  testAllocationStatistics();
  testRuntimeSample();
#endif
  std::puts("All diagnostics tests passed");
}
