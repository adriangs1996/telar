#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <dirent.h>
#include <fcntl.h>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <limits.h>
#include <string_view>
#include <sys/stat.h>
#include "telar_platform/random_bytes.hpp"
#include <atomic>
#include <cassert>
#include <cstddef>
#include "telar_base/memory/allocator.hpp"
#include <cstring>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <optional>
#include <chrono>
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <bit>
#include <utility>
#include <memory>
#include "telar_base/memory/fixed_text.hpp"
#include <pcap/pcap.h>
#include <charconv>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <arpa/inet.h>
#include <mutex>
#include <fstream>



import telar.platform;
import telar.runtime.traffic.control_backend;

using namespace telar;
using namespace telar::runtime;
using telar::Byte;
using telar::EncodingError;
namespace tr = telar::runtime::traffic;
namespace rec = telar::runtime::traffic::recording;

struct Clock {
  using time_point = std::chrono::steady_clock::time_point;
  static inline time_point instant{};
  static time_point now() noexcept { return instant; }
};

static tr::Event packet(std::uint64_t sequence, std::span<const Byte> bytes) {
  return {.kind = tr::Kind::packet, .session = 17, .sequence = sequence, .timestamp_us = 123456789, .interface_index = 3, .link_type = 1, .original_bytes = static_cast<std::uint32_t>(bytes.size() + 5), .interface = "en-test", .bytes = bytes};
}

static void retained() {
  SystemAllocator system;
  BudgetAllocator budget{system, 16 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  {
    tr::Recordings<decltype(memory), Clock> recordings{memory};
    SensitiveAllocation output{memory, rec::Limits::page_bytes};
    const auto start = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = 4096, .max_events = 3, .max_age_ms = 10, .selection = tr::Selection::packets}, output.bytes()));
    check(start.id != 0 && start.active && start.count == 0 && recordings.selects(tr::Selection::packets));
    check(!recordings.selects(tr::Selection::flows));
    constexpr std::array<Byte, 3> bytes{'a', 0, 'b'};
    for (std::uint64_t index = 1; index <= 6; ++index) { recordings.record(packet(index, bytes)); }
    auto page = rec::Protocol::page(recordings.handle({.id = start.id, .cursor = 1, .limit = 2}, output.bytes()));
    check(page.gap && page.oldest == 4 && page.next == 6 && page.end == 7 && page.evicted == 3 && page.count == 2 && page.dropped == 0);
    plugins::FrameReader rows{page.rows};
    for (std::uint64_t cursor = 4; cursor <= 5; ++cursor) {
      check(rows.integer<std::uint64_t>() == cursor);
      const auto event = tr::Protocol::decode(rows.bytes());
      check(event.sequence == cursor && event.interface == "en-test" && event.original_bytes == 8 && std::ranges::equal(event.bytes, bytes));
    }
    rows.finish();
    page = rec::Protocol::page(recordings.handle({.id = start.id, .cursor = page.next}, output.bytes()));
    check(!page.gap && page.count == 1 && page.next == page.end);
    page = rec::Protocol::page(recordings.handle({.operation = rec::Operation::stop, .id = start.id}, output.bytes()));
    check(!page.active && !recordings.selects(tr::Selection::packets));
    recordings.record(packet(7, bytes));
    page = rec::Protocol::page(recordings.handle({.id = start.id}, output.bytes()));
    check(page.count == 3 && page.end == 7);
    Clock::instant += std::chrono::milliseconds{11};
    recordings.expire();
    page = rec::Protocol::page(recordings.handle({.id = start.id, .cursor = 4}, output.bytes()));
    check(page.gap && page.count == 0 && page.evicted == 6 && page.oldest == page.end);
    recordings.handle({.operation = rec::Operation::erase, .id = start.id}, output.bytes());
    bool stale = false;
    try { recordings.handle({.id = start.id}, output.bytes()); } catch (const EncodingError &) { stale = true; }
    check(stale);
  }
  check(budget.liveBytes() == 0);
}

static void pagesAndExport() {
  SystemAllocator system;
  BudgetAllocator budget{system, 16 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  {
    tr::Recordings recordings{memory};
    SensitiveAllocation output{memory, rec::Limits::page_bytes};
    const auto start = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = 1024 * 1024, .max_events = 3}, output.bytes()));
    std::vector<Byte> bytes(tr::Limits::packet_bytes, 0x5a);
    recordings.record(packet(1, bytes));
    recordings.record(packet(2, bytes));
    auto page = rec::Protocol::page(recordings.handle({.id = start.id}, output.bytes()));
    check(page.count == 1 && page.next == 2 && page.end == 3);
    page = rec::Protocol::page(recordings.handle({.id = start.id, .cursor = page.next}, output.bytes()));
    check(page.count == 1 && page.next == 3);
    page = rec::Protocol::page(recordings.handle({.operation = rec::Operation::pcapng, .id = start.id, .limit = 1}, output.bytes()));
    check(page.count == 1 && page.next == 2);
    TemporaryDirectory directory{"/tmp/tlr-recording.XXXXXX"};
    const auto path = std::string{directory.path()} + "/capture.pcapng";
    {
      std::ofstream file{path, std::ios::binary};
      file.write(reinterpret_cast<const char *>(page.rows.data()), page.rows.size());
      check(file.good());
    }
    std::array<char, PCAP_ERRBUF_SIZE> error{};
    const std::unique_ptr<pcap_t, decltype(&pcap_close)> capture{pcap_open_offline(path.c_str(), error.data()), &pcap_close};
    check(capture != nullptr && pcap_datalink(capture.get()) == DLT_EN10MB);
    pcap_pkthdr *header = nullptr;
    const unsigned char *data = nullptr;
    check(pcap_next_ex(capture.get(), &header, &data) == 1);
    check(header->caplen == bytes.size() && header->len == bytes.size() + 5 && header->ts.tv_sec == 123 && header->ts.tv_usec == 456789);
    check(std::equal(bytes.begin(), bytes.end(), data));
    check(pcap_next_ex(capture.get(), &header, &data) == PCAP_ERROR_BREAK);
  }
  check(budget.liveBytes() == 0);
}

static void budgetsAndScopes() {
  SystemAllocator system;
  BudgetAllocator budget{system, 16 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  {
    tr::Recordings recordings{memory};
    SensitiveAllocation output{memory, rec::Limits::page_bytes};
    const auto start = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = 512, .max_events = 2, .selection = tr::Selection::packets}, output.bytes()));
    std::array<Byte, 220> body{};
    for (std::uint64_t index = 1; index <= 3; ++index) { recordings.record(packet(index, body)); }
    const auto page = rec::Protocol::page(recordings.handle({.id = start.id}, output.bytes()));
    check(page.count == 1 && page.bytes <= 512 && page.evicted == 2);
    const auto scoped = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = 4096, .max_events = 4, .selection = tr::Selection::flows, .host = "*.example.test"}, output.bytes()));
    std::array<Byte, 512> flow;
    auto payload = tr::FlowCodec::encode(flow, {.id = 31, .host = "sub.example.test"});
    recordings.record({.kind = tr::Kind::flow_open, .bytes = payload});
    payload = tr::FlowCodec::encode(flow, {.id = 32, .host = "other.test"});
    recordings.record({.kind = tr::Kind::flow_open, .bytes = payload});
    auto selected = rec::Protocol::page(recordings.handle({.id = scoped.id, .host = "SUB.EXAMPLE.TEST"}, output.bytes()));
    check(selected.count == 1);
    selected = rec::Protocol::page(recordings.handle({.id = scoped.id, .host = "other.test"}, output.bytes()));
    check(selected.count == 0 && selected.next == selected.end);
  }
  check(budget.liveBytes() == 0);
}

static void runtimeLimits() {
  SystemAllocator system;
  BudgetAllocator budget{system, 16 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  {
    tr::Recordings recordings{memory};
    SensitiveAllocation output{memory, rec::Limits::page_bytes};
    const auto rejected = [&](const rec::Request &request) {
      try { recordings.handle(request, output.bytes()); }
      catch (const std::exception &) { return true; }
      return false;
    };
    check(rejected({.operation = rec::Operation::start, .max_bytes = 1, .max_events = 1}));
    check(rejected({.operation = rec::Operation::start, .filter = "tcp and ("}));
    check(rec::Protocol::page(recordings.handle({.operation = rec::Operation::list}, output.bytes())).count == 0);
    const auto first = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = rec::Limits::session_bytes, .max_events = 1}, output.bytes())).id;
    const auto second = rec::Protocol::page(recordings.handle({.operation = rec::Operation::start, .max_bytes = rec::Limits::session_bytes, .max_events = 1}, output.bytes())).id;
    check(rejected({.operation = rec::Operation::start, .max_bytes = 4096, .max_events = 1}));
    recordings.handle({.operation = rec::Operation::erase, .id = first}, output.bytes());
    recordings.handle({.operation = rec::Operation::erase, .id = second}, output.bytes());
    for (std::size_t index = 0; index < rec::Limits::sessions; ++index) {
      recordings.handle({.operation = rec::Operation::start, .max_bytes = 4096, .max_events = 1}, output.bytes());
    }
    check(rejected({.operation = rec::Operation::start, .max_bytes = 4096, .max_events = 1}));
    check(rec::Protocol::page(recordings.handle({.operation = rec::Operation::list}, output.bytes())).count == rec::Limits::sessions);
  }
  check(budget.liveBytes() == 0);
}

int main() {
  retained();
  pagesAndExport();
  budgetsAndScopes();
  runtimeLimits();
  std::puts("Recordings: bounded retention, cursor gaps, expiry, binary pages, host scopes, stop/delete and libpcap-readable PCAPNG verified");
}
