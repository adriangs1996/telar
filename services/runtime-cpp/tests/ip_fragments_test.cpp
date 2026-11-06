#include "check.hpp"
#include "packet_fixture.hpp"
#include "tls_fixture.hpp"
#include "traffic/ip_fragments.hpp"
#include "traffic/tcp_flows.hpp"
#include "traffic/capture_analysis.hpp"
#include <random>

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::traffic;
using telar::Byte;

static void word(std::span<Byte> bytes, std::size_t offset, std::uint16_t value) {
  bytes[offset] = static_cast<Byte>(value >> 8);
  bytes[offset + 1] = static_cast<Byte>(value);
}

static std::vector<Byte> fragment(std::span<const Byte> original, std::size_t offset, std::size_t length, bool more, std::uint32_t id = 77) {
  const bool ipv6 = original[0] >> 4 == 6;
  const auto prefix = ipv6 ? 40u : 20u;
  std::vector<Byte> result(original.begin(), original.begin() + prefix);
  if (ipv6) {
    result.resize(prefix + 8);
    result[6] = 44;
    result[prefix] = 6;
    word(result, prefix + 2, static_cast<std::uint16_t>(offset) | (more ? 1 : 0));
    word(result, prefix + 4, static_cast<std::uint16_t>(id >> 16));
    word(result, prefix + 6, static_cast<std::uint16_t>(id));
    word(result, 4, static_cast<std::uint16_t>(8 + length));
  } else {
    word(result, 2, static_cast<std::uint16_t>(prefix + length));
    word(result, 4, static_cast<std::uint16_t>(id));
    word(result, 6, static_cast<std::uint16_t>(offset / 8) | (more ? 0x2000 : 0));
  }
  result.insert(result.end(), original.begin() + prefix + offset, original.begin() + prefix + offset + length);
  return result;
}

static Event packet(std::span<const Byte> bytes) {
  return {.session = 42, .interface_index = 7, .link_type = DLT_RAW, .original_bytes = static_cast<std::uint32_t>(bytes.size()), .interface = "fragment-fixture", .bytes = bytes};
}

static void reconstructed(TlsTestMemory &memory) {
  for (const bool ipv6 : {false, true}) {
    IpFragments fragments{memory};
    const std::string body{"binary\0fragmented-content", 25};
    const auto original = traffic_test::tcp(ipv6, false, 123, 16, body);
    const auto head = ipv6 ? 40u : 20u;
    const auto first = fragment(original, 0, 24, true);
    const auto last = fragment(original, 24, original.size() - head - 24, false);
    std::vector<Byte> completed;
    std::size_t calls = 0;
    const auto consume = [&](std::span<const Byte> bytes) { ++calls; completed.assign(bytes.begin(), bytes.end()); };
    const auto report = [](const Event &, std::string_view) { check(false); };
    fragments.packet(packet(last), consume, report);
    fragments.packet(packet(last), consume, report);
    check(calls == 0);
    fragments.packet(packet(first), consume, report);
    check(calls == 1 && completed.size() == original.size());
    const auto parsed = TcpPacketDecoder::decodeNetwork(completed);
    check(parsed && parsed->sequence == 123 && std::ranges::equal(parsed->bytes, body));
    check(std::ranges::equal(std::span{completed}.subspan(head), std::span{original}.subspan(head)));
    if (!ipv6) {
      std::uint32_t sum = 0;
      for (std::size_t index = 0; index < 20; index += 2) { sum += NetworkPacket::word(completed, index); }
      while (sum >> 16) { sum = (sum & UINT16_MAX) + (sum >> 16); }
      check(sum == UINT16_MAX);
    }
    fragments.expire(report, true);
  }
}

static void rejectedAndIsolated(TlsTestMemory &memory) {
  for (const bool ipv6 : {false, true}) {
    IpFragments fragments{memory};
    const auto original = traffic_test::tcp(ipv6, false, 1, 16, "0123456789abcdef");
    const auto first = fragment(original, 0, 24, true);
    const auto overlap = fragment(original, 16, 16, true);
    const auto last = fragment(original, 24, 12, false);
    std::vector<std::string> errors;
    std::size_t completed = 0;
    const auto consume = [&](std::span<const Byte>) { ++completed; };
    const auto report = [&](const Event &event, std::string_view reason) { check(event.interface == "fragment-fixture" && event.session == 42); errors.emplace_back(reason); };
    fragments.packet(packet(first), consume, report);
    fragments.packet(packet(overlap), consume, report);
    fragments.packet(packet(last), consume, report);
    check(completed == 0 && errors == std::vector<std::string>{"ip_fragment_overlap"});
    fragments.expire(report, true);
    errors.clear();

    fragments.packet(packet(first), consume, report);
    auto separate = packet(last);
    separate.interface_index = 8;
    fragments.packet(separate, consume, report);
    separate.interface_index = 7;
    separate.session = 43;
    fragments.packet(separate, consume, [](const Event &, std::string_view) { check(false); });
    check(completed == 0);
    fragments.packet(packet(last), consume, report);
    check(completed == 1);
    std::size_t expired = 0;
    fragments.expire([&](const Event &, std::string_view reason) { check(reason == "ip_fragment_timeout"); ++expired; }, false, std::chrono::steady_clock::now() + std::chrono::seconds{61});
    check(expired == 2);

    auto truncated = first;
    truncated.pop_back();
    fragments.packet(packet(truncated), consume, report);
    check(errors.back() == "ip_fragment_invalid_or_truncated");
    fragments.expire(report, true);
  }
}

static void atomicAndExtension(TlsTestMemory &memory) {
  IpFragments fragments{memory};
  const auto original = traffic_test::tcp(true, false, 1, 16, "0123456789abcdef");
  auto first = fragment(original, 0, 24, true);
  auto last = fragment(original, 24, 12, false);
  const auto atomic = fragment(original, 0, 36, false);
  std::size_t completed = 0;
  const auto consume = [&](std::span<const Byte> bytes) { check(TcpPacketDecoder::decodeNetwork(bytes).has_value()); ++completed; };
  const auto report = [](const Event &, std::string_view) { check(false); };
  fragments.packet(packet(first), consume, report);
  fragments.packet(packet(atomic), consume, report);
  check(completed == 1);
  fragments.packet(packet(last), consume, report);
  check(completed == 2);
  for (auto *part : {&first, &last}) {
    part->insert(part->begin() + 40, 8, 0);
    (*part)[6] = 0;
    (*part)[40] = 44;
    word(*part, 4, static_cast<std::uint16_t>(part->size() - 40));
  }
  fragments.packet(packet(last), consume, report);
  fragments.packet(packet(first), consume, report);
  check(completed == 3);
  fragments.expire(report, true);
}

static void capacityAndFlow(TlsTestMemory &memory) {
  IpFragments fragments{memory};
  const auto original = traffic_test::tcp(false, false, 10, 16, std::string_view{"a\0b-content-1234", 16});
  std::size_t capacity = 0;
  const auto report = [&](const Event &, std::string_view reason) { check(reason == "ip_fragment_capacity" || reason == "ip_fragment_capture_stopped"); capacity += reason == "ip_fragment_capacity"; };
  for (unsigned index = 0; index < 33; ++index) {
    const auto first = fragment(original, 0, 24, true, index);
    fragments.packet(packet(first), [](std::span<const Byte>) { check(false); }, report);
  }
  check(capacity == 1);
  fragments.expire(report, true);
  CaptureAnalysis flows{memory};
  std::string content;
  const auto emit = [&](const Event &event) {
    check(event.session == 42 && event.interface_index == 7 && event.interface == "fragment-fixture");
    const auto flow = FlowCodec::decode(event.bytes);
    if (event.kind == Kind::stream_data) { content.append(reinterpret_cast<const char *>(flow.bytes.data()), flow.bytes.size()); }
  };
  const auto last = fragment(original, 24, 12, false);
  const auto first = fragment(original, 0, 24, true);
  flows.packet(packet(last), Selection::flows, emit);
  flows.packet(packet(first), Selection::flows, emit);
  check(content == std::string("a\0b-content-1234", 16));
  flows.expire(emit, true);
}

static void malformedAndPieceLimits(TlsTestMemory &memory) {
  for (const bool ipv6 : {false, true}) {
    IpFragments fragments{memory};
    const auto original = traffic_test::tcp(ipv6, false, 1, 16, std::string(1100, 'x'));
    std::vector<std::string> errors;
    const auto report = [&](const Event &, std::string_view reason) { errors.emplace_back(reason); };
    const auto consume = [](std::span<const Byte>) { check(false); };
    for (std::size_t index = 0; index < 129; ++index) {
      const auto piece = fragment(original, index * 8, 8, true);
      fragments.packet(packet(piece), consume, report);
    }
    check(errors == std::vector<std::string>{"ip_fragment_piece_limit"});
    fragments.expire(report, true);
    errors.clear();

    const auto first = fragment(original, 0, 24, true);
    auto conflicting = first;
    conflicting.back() ^= 1;
    fragments.packet(packet(first), consume, report);
    fragments.packet(packet(conflicting), consume, report);
    check(errors == std::vector<std::string>{"ip_fragment_overlap"});
    fragments.expire(report, true);
    errors.clear();

    if (ipv6) {
      conflicting = first;
      conflicting[40] = 17;
      fragments.packet(packet(first), consume, report);
      fragments.packet(packet(conflicting), consume, report);
      check(errors == std::vector<std::string>{"ip_fragment_overlap"});
      fragments.expire(report, true);
      errors.clear();
    }

    for (std::size_t length = 0; length < first.size(); ++length) {
      fragments.packet(packet(std::span{first}.first(length)), [](std::span<const Byte>) {}, report);
    }
    fragments.expire(report, true);
  }

  IpFragments fragments{memory};
  std::minstd_rand random{7918200};
  std::vector<Byte> bytes;
  for (unsigned iteration = 0; iteration < 5000; ++iteration) {
    bytes.resize(random() % 512);
    for (auto &byte : bytes) { byte = static_cast<Byte>(random()); }
    if (bytes.size() >= 48) {
      bytes[0] = iteration % 2 == 0 ? 0x45 : 0x60;
      if (iteration % 2 == 0) {
        word(bytes, 2, static_cast<std::uint16_t>(bytes.size()));
        word(bytes, 6, 0x2000 | (random() % 8192));
      } else {
        word(bytes, 4, static_cast<std::uint16_t>(bytes.size() - 40));
        bytes[6] = 44;
      }
    }
    fragments.packet(packet(bytes), [](std::span<const Byte> completed) { check(completed.size() <= 65575); }, [](const Event &, std::string_view) {});
  }
  fragments.expire([](const Event &, std::string_view) {}, true);
}

int main() {
  SystemAllocator system;
  BudgetAllocator budget{system, 32 * 1024 * 1024};
  TlsTestMemory memory{budget};
  reconstructed(memory);
  rejectedAndIsolated(memory);
  atomicAndExtension(memory);
  capacityAndFlow(memory);
  malformedAndPieceLimits(memory);
  check(budget.liveBytes() == 0);
  std::puts("IPv4/IPv6 fragment ordering, duplicates, overlap rejection, provenance, atomic independence, expiry, capacity and TCP streams verified");
}
