#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <arpa/inet.h>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits.h>
#include <pcap/pcap.h>

import std;
import telar.base.memory.allocators;
import telar.base.memory.sensitive;
import telar.platform.primitives;
import telar.testing;
import telar.runtime.traffic.tests.packet_fixture;
import telar.tls.tests.tls_fixture;
import telar.runtime.traffic.capture_analysis;
import telar.runtime.traffic.control_backend;
import telar.vocabulary;
import telar.runtime.traffic.control_protocol;
import telar.runtime.vocabulary.frames;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::traffic;
  using telar::Byte;

  void word(std::span<Byte> bytes, std::size_t offset, std::uint16_t value) {
    bytes[offset] = static_cast<Byte>(value >> 8);
    bytes[offset + 1] = static_cast<Byte>(value);
  }

  std::vector<Byte> packet(bool ipv6, bool icmp, std::string_view body) {
    const auto prefix = ipv6 ? 40u : 20u;
    auto bytes = traffic_test::tcp(ipv6, false, 0, 0);

    bytes.resize(prefix + 8 + body.size());
    if (ipv6) {
      bytes[6] = icmp ? 58 : 17;
      word(bytes, 4, bytes.size() - 40);
    } else {
      bytes[9] = icmp ? 1 : 17;
      word(bytes, 2, bytes.size());
    }

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

  traffic::Event event(std::span<const Byte> bytes) {
    return {.session = 9, .sequence = 17, .timestamp_us = 234, .interface_index = 7, .link_type = DLT_RAW, .original_bytes = static_cast<std::uint32_t>(bytes.size()), .offline = true, .interface = "datagram-fixture", .bytes = bytes};
  }

  void analysisAndCodec(TlsTestMemory& memory) {
    for (const bool ipv6 : {false, true}) {
      for (const bool icmp : {false, true}) {
        CaptureAnalysis analysis{memory};
        const std::string body{"a\0b-datagram", 12};
        auto bytes = packet(ipv6, icmp, body);
        std::size_t received = 0;
        const auto emit = [&](const traffic::Event& item) {
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
        analysis.packet(event(bytes), Selection::datagrams, [&](const traffic::Event& item) {
          const auto parsed = DatagramCodec::decode(item.bytes);

          check(parsed.truncated && parsed.original_bytes == parsed.bytes.size() + 1);
          ++received;
        });

        check(received == 2);
        for (std::size_t prefix = 0; prefix < bytes.size(); ++prefix) {
          const auto ip = IpPayload::decode(std::span{bytes}.first(prefix));
          if (ip) {
            const auto parsed = DatagramCodec::parse(*ip);
            if (parsed) {
              check(parsed->truncated);
            }
          }
        }

        analysis.expire([](const traffic::Event&) {
          check(false);
        },
            true);
      }
    }
  }

  void fragmentedAndSelected(TlsTestMemory& memory) {
    const std::string body{"binary\0datagram-fragment", 24};

    for (const bool ipv6 : {false, true}) {
      const auto original = packet(ipv6, false, body);
      const auto prefix = ipv6 ? 40u : 20u;
      std::vector<Byte> first(original.begin(), original.begin() + prefix);
      std::vector<Byte> last = first;

      if (ipv6) {
        for (auto* piece : {&first, &last}) {
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
        word(first, 4, 55);
        word(last, 4, 55);
        word(first, 6, 0x2000);
        word(last, 6, 2);
        word(first, 2, prefix + 16);
        word(last, 2, prefix + original.size() - prefix - 16);
      }

      first.insert(first.end(), original.begin() + prefix, original.begin() + prefix + 16);
      last.insert(last.end(), original.begin() + prefix + 16, original.end());
      CaptureAnalysis analysis{memory};
      std::size_t count = 0;
      const auto emit = [&](const traffic::Event& item) {
        check(item.kind == Kind::datagram);
        check(std::ranges::equal(DatagramCodec::decode(item.bytes).bytes, body));
        ++count;
      };

      analysis.packet(event(last), Selection::datagrams, emit);
      check(count == 0);
      analysis.packet(event(first), Selection::datagrams, emit);
      check(count == 1);
      analysis.packet(event(original), Selection::flows, [](const traffic::Event&) {
        check(false);
      });

      analysis.expire([](const traffic::Event&) {
        check(false);
      },
          true);
    }
  }

  void recordedDatagrams(TlsTestMemory& memory) {
    Recordings recordings{memory};
    SensitiveAllocation output{memory, recording::Limits::page_bytes};
    const auto started = recording::Protocol::page(recordings.handle({.operation = recording::Operation::start, .max_bytes = 16384, .max_events = 4, .selection = Selection::datagrams}, output.bytesMut()));

    check(recordings.selects(Selection::datagrams) && !recordings.selects(Selection::flows));
    CaptureAnalysis analysis{memory};
    const auto bytes = packet(false, false, "recorded");

    analysis.packet(event(bytes), Selection::datagrams, [&](const traffic::Event& item) {
      recordings.record(item, {});
    });

    const auto page = recording::Protocol::page(recordings.handle({.id = started.id}, output.bytesMut()));

    check(page.count == 1);
    plugins::FrameReader rows{page.rows};

    check(rows.integer<std::uint64_t>() != 0);
    const auto item = Protocol::decode(rows.bytes());

    check(item.kind == Kind::datagram && DatagramCodec::decode(item.bytes).destination_port == 53);
    rows.finish();
  }

  template <typename Operation>
  void rejects(Operation operation) {
    bool rejected = false;

    try {
      operation();
    } catch (const std::exception&) {
      rejected = true;
    }

    check(rejected);
  }

  void malformedAndExtensions(TlsTestMemory& memory) {
    for (const bool ipv6 : {false, true}) {
      CaptureAnalysis analysis{memory};
      auto bytes = packet(ipv6, false, "body");
      const auto prefix = ipv6 ? 40u : 20u;

      for (const auto length : {0, 7, 13, 65535}) {
        word(bytes, prefix + 4, static_cast<std::uint16_t>(length));
        analysis.packet(event(bytes), Selection::datagrams, [](const traffic::Event&) {
          check(false);
        });
      }

      bytes = packet(ipv6, false, {});
      analysis.packet(event(bytes), Selection::datagrams, [](const traffic::Event& item) {
        check(DatagramCodec::decode(item.bytes).bytes.empty());
      });

      if (ipv6) {
        bytes = packet(true, false, "options");
        bytes.insert(bytes.begin() + 40, 8, 0);
        bytes[6] = 0;
        bytes[40] = 17;
        word(bytes, 4, bytes.size() - 40);
        analysis.packet(event(bytes), Selection::datagrams, [](const traffic::Event& item) {
          const auto parsed = DatagramCodec::decode(item.bytes);

          check(parsed.transport == DatagramTransport::udp && parsed.original_bytes == 7 && !parsed.truncated);
        });
      }
    }

    const auto bytes = packet(false, false, "body");
    const auto ip = IpPayload::decode(bytes);

    check(ip.hasValue());
    auto message = *DatagramCodec::parse(*ip);
    ds::Array<Byte, 256> output;
    const auto encoded = DatagramCodec::encode(output.viewMut(), message);

    for (std::size_t size = 0; size < encoded.size(); ++size) {
      rejects([&] {
        DatagramCodec::decode(encoded.first(size));
      });
    }

    message.source_address.atMut(15) = 1;
    rejects([&] {
      DatagramCodec::encode(output.viewMut(), message);
    });

    message.source_address.atMut(15) = 0;
    message.truncated = true;
    rejects([&] {
      DatagramCodec::encode(output.viewMut(), message);
    });

    const auto icmp = packet(false, true, "body");

    message = *DatagramCodec::parse(*IpPayload::decode(icmp));
    ++message.icmp_type;
    rejects([&] {
      DatagramCodec::encode(output.viewMut(), message);
    });
  }

  struct Received {
    bool ipv6;
    std::uint16_t source_port;
    std::uint16_t destination_port;
    std::vector<Byte> bytes;
    bool operator==(const Received&) const = default;
  };

  std::vector<Received> datagrams(TlsTestMemory& memory, std::span<const Byte> frame, std::uint32_t link_type) {
    CaptureAnalysis analysis{memory};
    auto captured = event(frame);
    std::vector<Received> received;

    captured.link_type = link_type;
    analysis.packet(captured, Selection::datagrams, [&](const traffic::Event& item) {
      check(item.kind == Kind::datagram);
      const auto parsed = DatagramCodec::decode(item.bytes);

      received.push_back({parsed.ipv6, parsed.source_port, parsed.destination_port, {parsed.bytes.begin(), parsed.bytes.end()}});
    });

    return received;
  }

  // Live capture on Ethernet and loopback interfaces, and imported pcaps, deliver link layers other
  // than raw IP: each framing of the same datagram yields the same event.
  void linkLayerFraming(TlsTestMemory& memory) {
    for (const bool ipv6 : {false, true}) {
      const auto datagram = packet(ipv6, false, "link-layer");
      const Byte high = ipv6 ? 0x86 : 0x08;
      const Byte low = ipv6 ? 0xdd : 0x00;
      const auto expected = datagrams(memory, datagram, DLT_RAW);

      check(expected.size() == 1 && expected.front().source_port == 53535 && expected.front().destination_port == 53);
      auto framed = [&](std::initializer_list<Byte> header) {
        std::vector<Byte> frame{header};

        frame.insert(frame.end(), datagram.begin(), datagram.end());
        return frame;
      };

      const std::vector<Byte> addresses(12, 0x02);
      auto ethernet = [&](std::initializer_list<Byte> tags) {
        std::vector<Byte> frame{addresses};

        frame.insert(frame.end(), tags);
        frame.insert(frame.end(), {high, low});
        frame.insert(frame.end(), datagram.begin(), datagram.end());
        return frame;
      };

      const Byte family = ipv6 ? 30 : 2;
      const ds::Array<std::pair<std::vector<Byte>, std::uint32_t>, 7> framings{{
          {ethernet({}), DLT_EN10MB},
          {ethernet({0x81, 0x00, 0x00, 0x07}), DLT_EN10MB},
          {ethernet({0x88, 0xa8, 0x00, 0x05, 0x81, 0x00, 0x00, 0x07}), DLT_EN10MB},
          {framed({family, 0, 0, 0}), DLT_NULL},
          {framed({0, 0, 0, family}), DLT_LOOP},
          {framed({0, 0, 0, 1, 0, 6, 2, 2, 2, 2, 2, 2, 0, 0, high, low}), DLT_LINUX_SLL},
          {framed({high, low, 0, 0, 0, 0, 0, 2, 0, 1, 0, 6, 2, 2, 2, 2, 2, 2, 0, 0}), DLT_LINUX_SLL2},
      }};

      for (const auto& [frame, link_type] : framings) {
        check(datagrams(memory, frame, link_type) == expected);
      }

      const auto plain = ethernet({});

      check(datagrams(memory, std::span{plain}.first(13), DLT_EN10MB).empty());
      auto arp = ethernet({});

      arp[12] = 0x08;
      arp[13] = 0x06;
      check(datagrams(memory, arp, DLT_EN10MB).empty());
      check(datagrams(memory, datagram, DLT_PPP).empty());
    }
  }

  // Routing, destination options and AH headers may precede a remote packet's UDP header; AH counts
  // its length in 4-byte words where the others count 8-byte units.
  void ipv6ExtensionChain(TlsTestMemory& memory) {
    const auto datagram = packet(true, false, "extensions");
    std::vector<Byte> extended{datagram.begin(), datagram.begin() + 40};
    const ds::Array<Byte, 8> routing{60, 0, 0, 0, 0, 0, 0, 0};
    const ds::Array<Byte, 8> options{51, 0, 1, 4, 0, 0, 0, 0};
    ds::Array<Byte, 24> authentication{17, 4};

    std::ranges::fill(authentication.viewMut().subspan(2), 0xa5);
    extended[6] = 43;
    extended.insert(extended.end(), routing.begin(), routing.end());
    extended.insert(extended.end(), options.begin(), options.end());
    extended.insert(extended.end(), authentication.begin(), authentication.end());
    extended.insert(extended.end(), datagram.begin() + 40, datagram.end());
    word(extended, 4, static_cast<std::uint16_t>(extended.size() - 40));
    const auto expected = datagrams(memory, datagram, DLT_RAW);

    check(expected.size() == 1 && datagrams(memory, extended, DLT_RAW) == expected);

    // The destination options run 16 bytes into a packet whose payload declares 8; the frame goes on
    // with a datagram after the packet, as an Ethernet trailer or the next capture bytes would.
    std::vector<Byte> overrun{datagram.begin(), datagram.begin() + 40};
    const ds::Array<Byte, 16> long_options{17, 1};

    overrun[6] = 60;
    word(overrun, 4, 8);
    overrun.insert(overrun.end(), long_options.begin(), long_options.end());
    overrun.insert(overrun.end(), datagram.begin() + 40, datagram.end());
    check(datagrams(memory, overrun, DLT_RAW).empty());
  }

  // Each case owns the budget its calls share and leaves nothing allocated there.
  template <auto body>
  void budgeted() {
    SystemAllocator system;
    BudgetAllocator budget{system, 32 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    TlsTestMemory& memory = adapter;

    body(memory);
    check(budget.liveBytes() == 0);
  }

  const telar::testing::Case case_analysis_and_codec{"datagram.analysis_and_codec", budgeted<analysisAndCodec>};
  const telar::testing::Case case_fragmented_and_selected{"datagram.fragmented_and_selected", budgeted<fragmentedAndSelected>};
  const telar::testing::Case case_recorded_datagrams{"datagram.recorded_datagrams", budgeted<recordedDatagrams>};
  const telar::testing::Case case_malformed_and_extensions{"datagram.malformed_and_extensions", budgeted<malformedAndExtensions>};
  const telar::testing::Case case_link_layer_framing{"datagram.link_layer_framing", budgeted<linkLayerFraming>};
  const telar::testing::Case case_ipv6_extension_chain{"datagram.ipv6_extension_chain", budgeted<ipv6ExtensionChain>};

}
