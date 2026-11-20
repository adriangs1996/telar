#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <pcap/pcap.h>

import std;
import telar.base.memory.allocators;
import telar.base.memory.sensitive;
import telar.platform.primitives;
import telar.testing;
import telar.platform.fs;
import telar.runtime.traffic.control_backend;
import telar.wire.vocabulary;
import telar.runtime.traffic.control_protocol;
import telar.runtime.traffic.tap.frames;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using telar::Byte;
  using telar::EncodingError;
  namespace tr = telar::runtime::traffic;
  namespace rec = telar::runtime::traffic::recording;

  struct Clock {
    using time_point = std::chrono::steady_clock::time_point;
    static inline time_point instant{};

    static time_point now() noexcept {
      return instant;
    }
  };

  tr::Event packet(std::uint64_t sequence, std::span<const Byte> bytes) {
    return {.kind = tr::Kind::packet, .session = 17, .sequence = sequence, .timestamp_us = 123456789, .interface_index = 3, .link_type = 1, .original_bytes = static_cast<std::uint32_t>(bytes.size() + 5), .interface = "en-test", .bytes = bytes};
  }

  void retained() {
    SystemAllocator system;
    BudgetAllocator budget{system, 16 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;

    {
      tr::Recordings<Clock> recordings{memory};
      SensitiveAllocation output{memory, rec::Limits::page_bytes};
      const auto start = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = 4096, .max_events = 3, .max_age_ms = 10, .selection = tr::Selection::packets}, output.bytesMut()));

      check(start.id != 0 && start.active && start.count == 0 && recordings.selects(tr::Selection::packets));
      check(!recordings.selects(tr::Selection::flows));
      constexpr ds::Array<Byte, 3> bytes{'a', 0, 'b'};

      for (std::uint64_t index = 1; index <= 6; ++index) {
        recordings.record(packet(index, bytes));
      }

      auto page = rec::Protocol::page(recordings.handle({.id = start.id, .cursor = 1, .limit = 2}, output.bytesMut()));

      check(page.gap && page.oldest == 4 && page.next == 6 && page.end == 7 && page.evicted == 3 && page.count == 2 && page.dropped == 0);
      plugins::FrameReader rows{page.rows};

      for (std::uint64_t cursor = 4; cursor <= 5; ++cursor) {
        check(rows.integer<std::uint64_t>() == cursor);
        const auto event = tr::Protocol::decode(rows.bytes());

        check(event.sequence == cursor && event.interface == "en-test" && event.original_bytes == 8 && std::ranges::equal(event.bytes, bytes));
      }

      rows.finish();
      page = rec::Protocol::page(recordings.handle({.id = start.id, .cursor = page.next}, output.bytesMut()));
      check(!page.gap && page.count == 1 && page.next == page.end);
      page = rec::Protocol::page(recordings.handle({.operation = rec::Operation::stop, .id = start.id}, output.bytesMut()));
      check(!page.active && !recordings.selects(tr::Selection::packets));
      recordings.record(packet(7, bytes));
      page = rec::Protocol::page(recordings.handle({.id = start.id}, output.bytesMut()));
      check(page.count == 3 && page.end == 7);
      Clock::instant += std::chrono::milliseconds{11};
      recordings.expire();
      page = rec::Protocol::page(recordings.handle({.id = start.id, .cursor = 4}, output.bytesMut()));
      check(page.gap && page.count == 0 && page.evicted == 6 && page.oldest == page.end);
      recordings.handle({.operation = rec::Operation::erase, .id = start.id}, output.bytesMut());
      bool stale = false;

      try {
        recordings.handle({.id = start.id}, output.bytesMut());
      } catch (const EncodingError&) {
        stale = true;
      }

      check(stale);
    }

    check(budget.liveBytes() == 0);
  }

  void pagesAndExport() {
    SystemAllocator system;
    BudgetAllocator budget{system, 16 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;

    {
      tr::Recordings recordings{memory};
      SensitiveAllocation output{memory, rec::Limits::page_bytes};
      const auto start = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = 1024 * 1024, .max_events = 3}, output.bytesMut()));
      std::vector<Byte> bytes(tr::Limits::packet_bytes, 0x5a);

      recordings.record(packet(1, bytes));
      recordings.record(packet(2, bytes));
      auto page = rec::Protocol::page(recordings.handle({.id = start.id}, output.bytesMut()));

      check(page.count == 1 && page.next == 2 && page.end == 3);
      page = rec::Protocol::page(recordings.handle({.id = start.id, .cursor = page.next}, output.bytesMut()));
      check(page.count == 1 && page.next == 3);
      page = rec::Protocol::page(recordings.handle({.operation = rec::Operation::pcapng, .id = start.id, .limit = 1}, output.bytesMut()));
      check(page.count == 1 && page.next == 2);
      TemporaryDirectory directory{"/tmp/tlr-recording.XXXXXX"};
      const auto path = std::string{directory.path()} + "/capture.pcapng";

      {
        std::ofstream file{path, std::ios::binary};

        file.write(reinterpret_cast<const char*>(page.rows.data()), page.rows.size());
        check(file.good());
      }

      ds::Array<char, PCAP_ERRBUF_SIZE> error{};
      const std::unique_ptr<pcap_t, decltype(&pcap_close)> capture{pcap_open_offline(path.c_str(), error.dataMut()), &pcap_close};

      check(capture != nullptr && pcap_datalink(capture.get()) == DLT_EN10MB);
      pcap_pkthdr* header = nullptr;
      const unsigned char* data = nullptr;

      check(pcap_next_ex(capture.get(), &header, &data) == 1);
      check(header->caplen == bytes.size() && header->len == bytes.size() + 5 && header->ts.tv_sec == 123 && header->ts.tv_usec == 456789);
      check(std::equal(bytes.begin(), bytes.end(), data));
      check(pcap_next_ex(capture.get(), &header, &data) == PCAP_ERROR_BREAK);
    }

    check(budget.liveBytes() == 0);
  }

  void budgetsAndScopes() {
    SystemAllocator system;
    BudgetAllocator budget{system, 16 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;

    {
      tr::Recordings recordings{memory};
      SensitiveAllocation output{memory, rec::Limits::page_bytes};
      const auto start = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = 512, .max_events = 2, .selection = tr::Selection::packets}, output.bytesMut()));
      ds::Array<Byte, 220> body{};

      for (std::uint64_t index = 1; index <= 3; ++index) {
        recordings.record(packet(index, body));
      }

      const auto page = rec::Protocol::page(recordings.handle({.id = start.id}, output.bytesMut()));

      check(page.count == 1 && page.bytes <= 512 && page.evicted == 2);
      const auto scoped = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = 4096, .max_events = 4, .selection = tr::Selection::flows, .host = "*.example.test"}, output.bytesMut()));
      ds::Array<Byte, 512> flow;
      auto payload = tr::FlowCodec::encode(flow.viewMut(), {.id = 31, .host = "sub.example.test"});

      recordings.record({.kind = tr::Kind::flow_open, .bytes = payload});
      payload = tr::FlowCodec::encode(flow.viewMut(), {.id = 32, .host = "other.test"});
      recordings.record({.kind = tr::Kind::flow_open, .bytes = payload});
      auto selected = rec::Protocol::page(recordings.handle({.id = scoped.id, .host = "SUB.EXAMPLE.TEST"}, output.bytesMut()));

      check(selected.count == 1);
      selected = rec::Protocol::page(recordings.handle({.id = scoped.id, .host = "other.test"}, output.bytesMut()));
      check(selected.count == 0 && selected.next == selected.end);
    }

    check(budget.liveBytes() == 0);
  }

  void runtimeLimits() {
    SystemAllocator system;
    BudgetAllocator budget{system, 16 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;

    {
      tr::Recordings recordings{memory};
      SensitiveAllocation output{memory, rec::Limits::page_bytes};
      const auto rejected = [&](const rec::Request& request) {
        try {
          recordings.handle(request, output.bytesMut());
        } catch (const std::exception&) {
          return true;
        }

        return false;
      };

      check(rejected({.operation = rec::Operation::start, .max_bytes = 1, .max_events = 1}));
      check(rejected({.operation = rec::Operation::start, .filter = "tcp and ("}));
      check(rec::Protocol::page(recordings.handle({.operation = rec::Operation::list}, output.bytesMut())).count == 0);
      const auto first = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = rec::Limits::session_bytes, .max_events = 1}, output.bytesMut())).id;
      const auto second = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = rec::Limits::session_bytes, .max_events = 1}, output.bytesMut())).id;

      check(rejected({.operation = rec::Operation::start, .max_bytes = 4096, .max_events = 1}));
      recordings.handle({.operation = rec::Operation::erase, .id = first}, output.bytesMut());
      recordings.handle({.operation = rec::Operation::erase, .id = second}, output.bytesMut());
      for (std::size_t index = 0; index < rec::Limits::sessions; ++index) {
        recordings.handle({.operation = rec::Operation::start, .max_bytes = 4096, .max_events = 1}, output.bytesMut());
      }

      check(rejected({.operation = rec::Operation::start, .max_bytes = 4096, .max_events = 1}));
      check(rec::Protocol::page(recordings.handle({.operation = rec::Operation::list}, output.bytesMut())).count == rec::Limits::sessions);
    }

    check(budget.liveBytes() == 0);
  }

  // A recording request names budgets the runtime then reserves: one past a published limit, or a
  // capture filter with a NUL that would cut it short, is refused and starts nothing.
  void requestValidation() {
    SystemAllocator system;
    BudgetAllocator budget{system, 16 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;

    {
      tr::Recordings recordings{memory};
      SensitiveAllocation output{memory, rec::Limits::page_bytes};
      const auto rejected = [&](const rec::Request& request) {
        try {
          recordings.handle(request, output.bytesMut());
        } catch (const EncodingError&) {
          return true;
        }

        return false;
      };

      check(rejected({.operation = rec::Operation::start, .max_bytes = rec::Limits::session_bytes + 1, .max_events = 1}));
      // A whole session's bytes, so its budget holds the larger index and only the event limit refuses.
      check(rejected({.operation = rec::Operation::start, .max_bytes = rec::Limits::session_bytes, .max_events = rec::Limits::events + 1}));
      check(rejected({.operation = rec::Operation::start, .max_bytes = 4096, .max_events = 1, .filter = std::string_view{"tcp\0 or udp", 11}}));
      check(rec::Protocol::page(recordings.handle({.operation = rec::Operation::list}, output.bytesMut())).count == 0);
    }

    check(budget.liveBytes() == 0);
  }

  const telar::testing::Case case_retained{
      "traffic_recording.retained",
      [] {
        retained();
      },
  };
  const telar::testing::Case case_pages_and_export{
      "traffic_recording.pages_and_export",
      [] {
        pagesAndExport();
      },
  };
  const telar::testing::Case case_budgets_and_scopes{
      "traffic_recording.budgets_and_scopes",
      [] {
        budgetsAndScopes();
      },
  };
  const telar::testing::Case case_runtime_limits{
      "traffic_recording.runtime_limits",
      [] {
        runtimeLimits();
      },
  };
  const telar::testing::Case case_request_validation{
      "traffic_recording.request_validation",
      [] {
        requestValidation();
      },
  };

}
