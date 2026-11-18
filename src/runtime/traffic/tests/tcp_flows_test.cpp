#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <pcap/pcap.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.runtime.traffic.tests.packet_fixture;
import telar.runtime.traffic.capture_analysis;
import telar.runtime.traffic.control_protocol;
import telar.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::traffic;
  using telar::Byte;

  constexpr Byte fin = 1, syn = 2, ack = 16;

  struct Published {
    Kind kind;
    std::uint64_t id;
    std::string reason;
    std::string bytes;
    std::string client;
    std::string server;
  };

  // A capture of one TCP connection, fed segment by segment, and what the flows publish from it.
  struct Capture {
    explicit Capture(ConcurrentMemory& memory)
        : flows(memory) {}

    void send(bool incoming, std::uint32_t sequence, Byte flags, std::string_view body = {}, std::size_t cut = 0) {
      const auto packet = traffic_test::tcp(false, incoming, sequence, flags, body);

      deliver(std::span{packet}.first(packet.size() - cut), packet.size());
    }

    void deliver(std::span<const Byte> captured, std::size_t original) {
      flows.packet(traffic::Event{.session = 3, .interface_index = 1, .link_type = DLT_RAW, .original_bytes = static_cast<std::uint32_t>(original), .interface = "fixture", .bytes = captured}, [&](const traffic::Event& event) {
        const auto flow = FlowCodec::decode(event.bytes);

        published.push_back({event.kind, flow.id, std::string{flow.reason}, std::string{reinterpret_cast<const char*>(flow.bytes.data()), flow.bytes.size()}, std::string{flow.client}, std::string{flow.server}});
      });
    }

    std::string data() const {
      std::string output;

      for (const auto& event : published) {
        if (event.kind == Kind::stream_data) {
          output += event.bytes;
        }
      }

      return output;
    }

    std::vector<std::string> closed() const {
      std::vector<std::string> reasons;

      for (const auto& event : published) {
        if (event.kind == Kind::flow_close) {
          reasons.push_back(event.reason);
        }
      }

      return reasons;
    }

    TcpFlows flows;
    std::vector<Published> published;
  };

  // Each guard keeps bytes a capture cannot vouch for, a segment cut by the snap length, data past
  // the sender's FIN, or a new connection on a reused tuple, out of the stream plugins and
  // recordings receive.
  void testAdversarialSegments() {
    SystemAllocator system;
    SynchronizedAllocator synchronized{system};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;

    {
      Capture capture{memory};

      capture.send(false, 0, syn);
      capture.send(true, 9, syn | ack);
      capture.send(false, 1, ack, "kept");
      capture.send(false, 5, ack, "lost", 2);
      check(capture.data() == "kept" && capture.closed() == std::vector<std::string>{"truncated_packet"});
      check(std::ranges::any_of(capture.published, [](const Published& event) {
        return event.kind == Kind::flow_gap && event.reason == "truncated_packet";
      }));
    }

    {
      Capture capture{memory};

      capture.send(false, 0, syn);
      capture.send(true, 9, syn | ack);
      capture.send(false, 1, ack | fin, "done");
      capture.send(false, 6, ack, "late");
      check(capture.data() == "done" && capture.closed() == std::vector<std::string>{"data_after_fin"});
    }

    {
      Capture capture{memory};

      capture.send(false, 0, syn);
      capture.send(true, 9, syn | ack);
      capture.send(false, 1, ack, "first");
      capture.send(false, 5000, syn);
      capture.send(true, 700, syn | ack);
      capture.send(false, 5001, ack, "second");
      check(capture.closed() == std::vector<std::string>{"tuple_reused"});

      std::vector<std::uint64_t> opened;
      std::map<std::uint64_t, std::string> streams;

      for (const auto& event : capture.published) {
        if (event.kind == Kind::flow_open) {
          opened.push_back(event.id);
        } else if (event.kind == Kind::stream_data) {
          streams[event.id] += event.bytes;
        }
      }

      check(opened.size() == 2 && opened[0] != opened[1]);
      check(streams[opened[0]] == "first" && streams[opened[1]] == "second");
    }
  }

  // A capture opening flows without end keeps a bounded table: each flow it drops to make room is
  // closed in public, with the reason. A flow first seen at its SYN-ACK names the sender of that
  // SYN-ACK as the server.
  void testCapacityAndOrientation() {
    SystemAllocator system;
    SynchronizedAllocator synchronized{system};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;

    {
      Capture capture{memory};
      constexpr std::size_t flows = 1000;

      for (std::size_t index = 0; index < flows; ++index) {
        auto packet = traffic_test::tcp(false, false, 0, syn);
        const auto port = static_cast<std::uint16_t>(10000 + index);

        packet[20] = static_cast<Byte>(port >> 8);
        packet[21] = static_cast<Byte>(port);
        capture.deliver(packet, packet.size());
      }

      const auto opened = std::ranges::count(capture.published, Kind::flow_open, &Published::kind);
      const auto closed = capture.closed();

      check(opened == flows && !closed.empty() && static_cast<std::size_t>(opened) - closed.size() < flows);
      check(std::ranges::all_of(closed, [](const std::string& reason) {
        return reason == "flow_limit";
      }));
    }

    {
      Capture capture{memory};

      capture.send(true, 9, syn | ack);
      const auto open = std::ranges::find(capture.published, Kind::flow_open, &Published::kind);

      check(open != capture.published.end() && open->server.ends_with(":80") && open->client.ends_with(":50000"));
    }
  }

  const telar::testing::Case case_adversarial_segments{"tcp_flows.adversarial_segments", testAdversarialSegments};
  const telar::testing::Case case_capacity_and_orientation{"tcp_flows.capacity_and_orientation", testCapacityAndOrientation};

}
