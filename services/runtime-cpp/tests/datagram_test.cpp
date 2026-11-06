#include "check.hpp"
#include "packet_fixture.hpp"
#include "tls_fixture.hpp"
#include "traffic/capture_analysis.hpp"
#include "traffic/recordings.hpp"

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::traffic;
using telar::Byte;

static void word(std::span<Byte> bytes, std::size_t offset, std::uint16_t value) {
  bytes[offset] = static_cast<Byte>(value >> 8);
  bytes[offset + 1] = static_cast<Byte>(value);
}

static std::vector<Byte> packet(bool ipv6, bool icmp, std::string_view body) {
  const auto prefix = ipv6 ? 40u : 20u;
  auto bytes = traffic_test::tcp(ipv6, false, 0, 0);
  bytes.resize(prefix + 8 + body.size());
  if (ipv6) { bytes[6] = icmp ? 58 : 17; word(bytes, 4, bytes.size() - 40); }
  else { bytes[9] = icmp ? 1 : 17; word(bytes, 2, bytes.size()); }
  if (icmp) {
    bytes[prefix] = ipv6 ? 128 : 8;
    bytes[prefix + 1] = 0;
    word(bytes, prefix + 2, 0);
    word(bytes, prefix + 4, 456);
    word(bytes, prefix + 6, 789);
  } else {
    word(bytes, prefix, 53535);
    word(bytes, prefix + 2, 53);
    word(bytes, prefix + 4, 8 + body.size());
    word(bytes, prefix + 6, 0);
  }
  std::ranges::copy(body, bytes.begin() + prefix + 8);
  return bytes;
}

static Event event(std::span<const Byte> bytes) {
  return {.session = 9, .sequence = 17, .timestamp_us = 234, .interface_index = 7, .link_type = DLT_RAW, .original_bytes = static_cast<std::uint32_t>(bytes.size()), .offline = true, .interface = "datagram-fixture", .bytes = bytes};
}

static void analysisAndCodec(TlsTestMemory &memory) {
  for (const bool ipv6 : {false, true}) {
    for (const bool icmp : {false, true}) {
      CaptureAnalysis analysis{memory};
      const std::string body{"a\0b-datagram", 12};
      auto bytes = packet(ipv6, icmp, body);
      std::size_t received = 0;
      const auto emit = [&](const Event &item) {
        check(item.kind == Kind::datagram && item.session == 9 && item.sequence == 17 && item.interface_index == 7 && item.interface == "datagram-fixture" && item.offline);
        const auto parsed = DatagramCodec::decode(item.bytes);
        check(parsed.ipv6 == ipv6 && !parsed.truncated);
        check(std::string{IpPayload::addressText(parsed.source_address, ipv6).data()} == (ipv6 ? "::1" : "0.0.0.1"));
        if (icmp) {
          check(parsed.transport == (ipv6 ? DatagramTransport::icmpv6 : DatagramTransport::icmp));
          check(parsed.icmp_type == (ipv6 ? 128 : 8) && parsed.icmp_code == 0 && parsed.echo());
          check(NetworkPacket::word(parsed.bytes, 4) == 456 && NetworkPacket::word(parsed.bytes, 6) == 789);
          check(std::ranges::equal(parsed.bytes.subspan(8), body));
        } else {
          check(parsed.transport == DatagramTransport::udp && parsed.source_port == 53535 && parsed.destination_port == 53 && !parsed.echo());
          check(std::ranges::equal(parsed.bytes, body));
        }
        ++received;
      };
      analysis.packet(event(bytes), Selection::datagrams, emit);
      check(received == 1);
      bytes.pop_back();
      analysis.packet(event(bytes), Selection::datagrams, [&](const Event &item) {
        const auto parsed = DatagramCodec::decode(item.bytes);
        check(parsed.truncated && parsed.original_bytes == parsed.bytes.size() + 1);
        ++received;
      });
      check(received == 2);
      for (std::size_t prefix = 0; prefix < bytes.size(); ++prefix) {
        const auto ip = IpPayload::decode(std::span{bytes}.first(prefix));
        if (ip) {
          const auto parsed = DatagramCodec::parse(*ip);
          if (parsed) { check(parsed->truncated); }
        }
      }
      analysis.expire([](const Event &) { check(false); }, true);
    }
  }
}

static void fragmentedAndSelected(TlsTestMemory &memory) {
  const std::string body{"binary\0datagram-fragment", 24};
  for (const bool ipv6 : {false, true}) {
    const auto original = packet(ipv6, false, body);
    const auto prefix = ipv6 ? 40u : 20u;
    std::vector<Byte> first(original.begin(), original.begin() + prefix);
    std::vector<Byte> last = first;
    if (ipv6) {
      for (auto *piece : {&first, &last}) {
        piece->resize(48);
        (*piece)[6] = 44;
        (*piece)[40] = 17;
        word(*piece, 46, 55);
      }
      word(first, 42, 1);
      word(last, 42, 16);
      word(first, 4, 24);
      word(last, 4, 8 + original.size() - prefix - 16);
    } else {
      word(first, 4, 55); word(last, 4, 55);
      word(first, 6, 0x2000); word(last, 6, 2);
      word(first, 2, prefix + 16);
      word(last, 2, prefix + original.size() - prefix - 16);
    }
    first.insert(first.end(), original.begin() + prefix, original.begin() + prefix + 16);
    last.insert(last.end(), original.begin() + prefix + 16, original.end());
    CaptureAnalysis analysis{memory};
    std::size_t count = 0;
    const auto emit = [&](const Event &item) {
      check(item.kind == Kind::datagram);
      check(std::ranges::equal(DatagramCodec::decode(item.bytes).bytes, body));
      ++count;
    };
    analysis.packet(event(last), Selection::datagrams, emit);
    check(count == 0);
    analysis.packet(event(first), Selection::datagrams, emit);
    check(count == 1);
    analysis.packet(event(original), Selection::flows, [](const Event &) { check(false); });
    analysis.expire([](const Event &) { check(false); }, true);
  }
}

static void recordedDatagrams(TlsTestMemory &memory) {
  Recordings recordings{memory};
  SensitiveAllocation output{memory, recording::Limits::page_bytes};
  const auto started = recording::Protocol::page(recordings.handle({.operation = recording::Operation::start, .max_bytes = 16384, .max_events = 4, .selection = Selection::datagrams}, output.bytes()));
  check(recordings.selects(Selection::datagrams) && !recordings.selects(Selection::flows));
  CaptureAnalysis analysis{memory};
  const auto bytes = packet(false, false, "recorded");
  analysis.packet(event(bytes), Selection::datagrams, [&](const Event &item) { recordings.record(item, {}); });
  const auto page = recording::Protocol::page(recordings.handle({.id = started.id}, output.bytes()));
  check(page.count == 1);
  plugins::FrameReader rows{page.rows};
  check(rows.integer<std::uint64_t>() != 0);
  const auto item = Protocol::decode(rows.bytes());
  check(item.kind == Kind::datagram && DatagramCodec::decode(item.bytes).destination_port == 53);
  rows.finish();
}

template <typename Operation>
static void rejects(Operation operation) {
  bool rejected = false;
  try { operation(); } catch (const std::exception &) { rejected = true; }
  check(rejected);
}

static void malformedAndExtensions(TlsTestMemory &memory) {
  for (const bool ipv6 : {false, true}) {
    CaptureAnalysis analysis{memory};
    auto bytes = packet(ipv6, false, "body");
    const auto prefix = ipv6 ? 40u : 20u;
    for (const auto length : {0, 7, 13, 65535}) {
      word(bytes, prefix + 4, static_cast<std::uint16_t>(length));
      analysis.packet(event(bytes), Selection::datagrams, [](const Event &) { check(false); });
    }
    bytes = packet(ipv6, false, {});
    analysis.packet(event(bytes), Selection::datagrams, [](const Event &item) { check(DatagramCodec::decode(item.bytes).bytes.empty()); });
    if (ipv6) {
      bytes = packet(true, false, "options");
      bytes.insert(bytes.begin() + 40, 8, 0);
      bytes[6] = 0;
      bytes[40] = 17;
      word(bytes, 4, bytes.size() - 40);
      analysis.packet(event(bytes), Selection::datagrams, [](const Event &item) {
        const auto parsed = DatagramCodec::decode(item.bytes);
        check(parsed.transport == DatagramTransport::udp && parsed.original_bytes == 7 && !parsed.truncated);
      });
    }
  }
  const auto bytes = packet(false, false, "body");
  const auto ip = IpPayload::decode(bytes);
  check(ip.has_value());
  auto message = *DatagramCodec::parse(*ip);
  std::array<Byte, 256> output;
  const auto encoded = DatagramCodec::encode(output, message);
  for (std::size_t size = 0; size < encoded.size(); ++size) { rejects([&] { DatagramCodec::decode(encoded.first(size)); }); }
  message.source_address[15] = 1;
  rejects([&] { DatagramCodec::encode(output, message); });
  message.source_address[15] = 0;
  message.truncated = true;
  rejects([&] { DatagramCodec::encode(output, message); });
  const auto icmp = packet(false, true, "body");
  message = *DatagramCodec::parse(*IpPayload::decode(icmp));
  ++message.icmp_type;
  rejects([&] { DatagramCodec::encode(output, message); });
}

int main() {
  SystemAllocator system;
  BudgetAllocator budget{system, 32 * 1024 * 1024};
  TlsTestMemory memory{budget};
  analysisAndCodec(memory);
  fragmentedAndSelected(memory);
  recordedDatagrams(memory);
  malformedAndExtensions(memory);
  check(budget.liveBytes() == 0);
  std::puts("UDP/ICMP/ICMPv6 metadata, binary boundaries, truncation, fragments, selection and recording verified");
}
