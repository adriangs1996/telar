#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <arpa/inet.h>
#include <brotli/decode.h>
#include <brotli/encode.h>
#include <cassert>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <nghttp2/nghttp2.h>
#include <pcap/pcap.h>
#include <sys/socket.h>
#include <unistd.h>
#include <zlib.h>
#include <zstd.h>

import std;
import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.testing;
import telar.runtime.traffic.tests.packet_fixture;
import telar.testing.test_byte_stream;
import telar.runtime.traffic.control_backend;
import telar.runtime.traffic.capture_analysis;
import telar.runtime.proxy.runtime;
import telar.wire.vocabulary;
import telar.config.runtime;
import telar.platform.net;
import telar.runtime.exchange_capture.producer;
import telar.runtime.proxy.http2_capture_streams;
import telar.runtime.traffic.control_protocol;
import telar.runtime.http2.direction_observer;
import telar.runtime.http2.frame_reader;
import telar.runtime.vocabulary.exchange;
import telar.runtime.http2.tests.http2_fixture;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::traffic;
  using telar::Byte;
  using traffic_test::tcp;

  struct Control : FlowControl {
    explicit Control(ConcurrentMemory& memory)
        : broker(memory) {
      broker.configure({.host = "fixture.test", .visibility = 3});
    }

    Interception<> broker;
    std::uint64_t ticket = 0;
    std::size_t requests = 0;
    std::string forwarded;

    void observeFlow(Kind kind, const FlowEvent& event) noexcept override {
      if (kind == Kind::stream_data) {
        forwarded.append(reinterpret_cast<const char*>(event.bytes.data()), event.bytes.size());
      }
    }

    std::uint64_t intercept(const FlowEvent& event) noexcept override {
      ++requests;
      return ticket = broker.begin(event);
    }

    Decision poll(std::uint64_t id, std::span<Byte> bytes) noexcept override {
      return broker.poll(id, bytes);
    }

    void cancel(std::uint64_t id) noexcept override {
      broker.cancel(id);
    }

    ds::Option<Time> deadline(std::uint64_t id) noexcept override {
      return broker.deadline(id);
    }

    int descriptor() const noexcept override {
      return broker.descriptor();
    }

    void drain() noexcept override {
      broker.drain();
    }
  };

  struct PartialStream {
    std::string output;
    bool block = true;

    StreamResult read(std::span<Byte>) noexcept {
      return {StreamResult::State::blocked};
    }

    StreamResult write(std::span<const Byte> bytes) noexcept {
      if (block) {
        block = false;
        return {StreamResult::State::blocked, 0, StreamReadiness::writable};
      }

      const auto count = std::min(bytes.size(), std::size_t{3});

      output.append(reinterpret_cast<const char*>(bytes.data()), count);
      return {StreamResult::State::data, count};
    }

    void halfClose() noexcept {}
  };

  void gates(ConcurrentMemory& memory) {
    for (const auto verdict : {Verdict::allow, Verdict::replace, Verdict::reject}) {
      Control control{memory};
      FlowState gate;

      gate.open(&control, 1, -1, -1, "fixture.test");
      PartialStream stream;
      const std::array<Byte, 3> original{'o', 0, 'd'};
      const std::array<Byte, 7> replacement{'c', 'h', 0, 'n', 'g', 'e', 'd'};

      check(gate.write(traffic::Direction::outbound, stream, original).state == StreamResult::State::blocked && stream.output.empty());
      check(gate.deadline().hasValue());
      control.broker.decide(control.ticket, verdict, verdict == Verdict::replace ? std::span<const Byte>{replacement} : std::span<const Byte>{});
      StreamResult result{StreamResult::State::blocked};

      for (unsigned attempt = 0; attempt < 10 && result.state == StreamResult::State::blocked; ++attempt) {
        result = gate.write(traffic::Direction::outbound, stream, original);
      }

      check(control.requests == 1);
      if (verdict == Verdict::reject) {
        check(gate.rejected() && stream.output.empty());
      } else {
        check(result.state == StreamResult::State::data && result.bytes == original.size());
        const auto expected = verdict == Verdict::replace ? std::span<const Byte>{replacement} : std::span<const Byte>{original};

        check(std::ranges::equal(stream.output, expected));
        check(control.forwarded == stream.output);
      }
    }

    // A hook deletes a chunk by replacing it with nothing: none of it is written, the write reports
    // it consumed, and the next chunk goes to the hook again.
    {
      Control control{memory};
      FlowState gate;

      gate.open(&control, 3, -1, -1, "fixture.test");
      PartialStream stream;
      const std::array<Byte, 3> original{'o', 0, 'd'};

      check(gate.write(traffic::Direction::outbound, stream, original).state == StreamResult::State::blocked);
      control.broker.decide(control.ticket, Verdict::replace, {});
      const auto deleted = gate.write(traffic::Direction::outbound, stream, original);

      check(deleted.state == StreamResult::State::data && deleted.bytes == original.size() && stream.output.empty());
      check(gate.write(traffic::Direction::outbound, stream, original).state == StreamResult::State::blocked && control.requests == 2);
    }

    {
      Control control{memory};

      control.broker.disconnect();
      FlowState gate;

      gate.open(&control, 2, -1, -1, "fixture.test");
      PartialStream stream;
      const std::array<Byte, 3> original{'o', 'l', 'd'};

      check(gate.write(traffic::Direction::outbound, stream, original).state == StreamResult::State::blocked);
      control.broker.configure({.host = "fixture.test", .visibility = 3});
      check(gate.write(traffic::Direction::outbound, stream, original).state == StreamResult::State::data);
      check(control.requests == 1 && stream.output == "old");
    }

    ProxyHostPolicy hosts{memory};

    check(hosts.append("0:0:0:0:0:0:0:1") && !hosts.append("[::1]") && !hosts.append("host:443"));
    hosts.finish();
    check(hosts.contains("::1") && !hosts.contains("::2"));
    Interception broker{memory};

    broker.configure({.host = "*.fixture.test", .timeout_ms = 1, .fail_closed = true});
    check(broker.begin({.visibility = Visibility::plaintext, .host = "fixture.test"}) == 0);
    std::array<Byte, FlowControl::chunk_bytes> bytes;
    const auto ticket = broker.begin({.visibility = Visibility::plaintext, .host = "a.fixture.test"});

    check(ticket != 0 && broker.poll(ticket, bytes).verdict == Verdict::pending);
    std::this_thread::sleep_for(std::chrono::milliseconds{3});
    check(broker.poll(ticket, bytes).verdict == Verdict::reject);
    broker.disconnect();
    broker.configure({.host = "*", .visibility = 3, .fail_closed = false});
    const auto disconnected = broker.begin({.host = "fixture.test"});

    broker.disconnect();
    check(broker.poll(disconnected, bytes).verdict == Verdict::allow);
  }

  void composition(ConcurrentMemory& memory) {
    Interception broker{memory};
    const InterceptionRule rule{.host = "fixture.test", .visibility = 3, .timeout_ms = 5000};

    broker.configure(11, rule);
    broker.configure(22, rule);
    const std::array<Byte, 3> original{'o', 0, 'd'};
    const std::array<Byte, 5> replacement{'e', 'd', 0, 'i', 't'};
    std::array<Byte, FlowControl::chunk_bytes> output;
    auto take = [&](std::uint64_t owner, std::span<const Byte> expected) {
      std::uint64_t ticket = 0;

      broker.deliver(owner, [&](const FlowEvent& event) {
        check(ticket == 0 && std::ranges::equal(event.bytes, expected));
        ticket = event.ticket;
        return true;
      });

      return ticket;
    };

    const auto first = broker.begin({.host = "fixture.test", .bytes = original});

    check(take(22, original) == 0);
    check(take(11, original) == first && take(11, original) == 0);
    broker.decide(22, first, Verdict::reject, {});
    check(broker.poll(first, output).verdict == Verdict::pending);
    broker.configure(33, rule);
    broker.decide(11, first, Verdict::replace, replacement);
    const auto second = take(22, replacement);

    check(second != 0 && second != first);
    broker.decide(11, second, Verdict::reject, {});
    broker.decide(22, first, Verdict::reject, {});
    check(broker.poll(first, output).verdict == Verdict::pending);
    broker.disconnect(22);
    const auto result = broker.poll(first, output);

    check(result.verdict == Verdict::replace && std::ranges::equal(std::span{output}.first(result.bytes), replacement));
    check(take(33, original) == 0);

    broker.configure(22, rule);
    const auto ordered = broker.begin({.host = "fixture.test", .bytes = original});

    check(take(11, original) == ordered);
    broker.decide(11, ordered, Verdict::allow, {});
    check(take(22, original) == 0);
    const auto third = take(33, original);

    broker.decide(33, third, Verdict::reject, {});
    check(broker.poll(ordered, output).verdict == Verdict::reject && take(22, original) == 0);

    const auto generation = broker.begin({.host = "fixture.test", .bytes = original});

    broker.disconnect(33);
    broker.configure(33, rule);
    broker.decide(11, generation, Verdict::allow, {});
    check(take(33, original) == 0);
    const auto last = take(22, original);

    check(last != 0);
    broker.decide(22, last, Verdict::replace, {});
    check(broker.poll(generation, output).verdict == Verdict::replace);

    broker.disconnect(11);
    broker.disconnect(22);
    broker.disconnect(33);
    broker.configure(44, {.host = "*", .visibility = 3, .timeout_ms = 1});
    broker.configure(55, {.host = "*", .visibility = 3, .timeout_ms = 5000, .fail_closed = true});
    const auto timed = broker.begin({.host = "fixture.test", .bytes = original});

    std::this_thread::sleep_for(std::chrono::milliseconds{3});
    check(broker.poll(timed, output).verdict == Verdict::pending);
    check(take(55, original) != 0);
    broker.disconnect(55);
    check(broker.poll(timed, output).verdict == Verdict::reject);

    const auto overloaded = broker.begin({.host = "fixture.test", .bytes = original});

    broker.deliver(44, [](const FlowEvent&) {
      return false;
    });

    check(broker.poll(overloaded, output).verdict == Verdict::allow);
    broker.disconnect(44);
    broker.configure(66, {.host = "*", .visibility = 3, .fail_closed = true});
    const auto undeliverable = broker.begin({.host = "fixture.test", .bytes = original});

    broker.deliver(66, [](const FlowEvent&) -> bool {
      throw std::bad_alloc{};
    });

    check(broker.poll(undeliverable, output).verdict == Verdict::reject);
    const auto canceled = broker.begin({.host = "fixture.test", .bytes = original});

    broker.cancel(canceled);
    broker.decide(66, canceled, Verdict::replace, replacement);
    check(broker.poll(canceled, output).verdict == Verdict::reject && take(66, original) == 0);

    for (unsigned count = 0; count < 64; ++count) {
      check(broker.begin({.host = "fixture.test", .bytes = original}) != Interception<>::rejected_ticket);
    }

    check(broker.begin({.host = "fixture.test", .bytes = original}) == Interception<>::rejected_ticket);
  }

  void reconstruction(ConcurrentMemory& memory) {
    for (bool ipv6 : {false, true}) {
      TcpFlows flows{memory};
      std::string outbound, inbound;
      std::vector<Kind> kinds;
      auto consume = [&](const traffic::Event& event) {
        check(event.offline == ipv6);
        const auto flow = FlowCodec::decode(event.bytes);

        check(flow.id >> 63 && flow.source == FlowSource::capture);
        if (event.kind == Kind::stream_data) {
          auto& output = flow.direction == traffic::Direction::outbound ? outbound : inbound;

          check(flow.offset == output.size());
          output.append(reinterpret_cast<const char*>(flow.bytes.data()), flow.bytes.size());
        }

        kinds.push_back(event.kind);
      };

      auto send = [&](bool incoming, std::uint32_t sequence, Byte flags, std::string_view body = {}) {
        const auto packet = tcp(ipv6, incoming, sequence, flags, body);
        traffic::Event event{.session = 11, .interface_index = 1, .link_type = DLT_RAW, .original_bytes = static_cast<std::uint32_t>(packet.size()), .offline = ipv6, .interface = "fixture", .bytes = packet};

        flows.packet(event, consume);
        for (std::size_t prefix = 0; prefix < packet.size(); ++prefix) {
          event.bytes = std::span{packet}.first(prefix);
          const auto decoded = TcpPacketDecoder::decode(event);
          if (decoded) {
            check(decoded->truncated);
          }
        }
      };

      send(false, UINT32_MAX - 2, 2);
      send(true, 9, 18);
      send(false, 1, 16, "def");
      send(false, UINT32_MAX - 1, 16, "abc");
      send(false, UINT32_MAX - 1, 16, "abc");
      send(true, 10, 16, std::string_view{"x\0y", 3});
      send(false, 4, 17);
      send(true, 13, 17);
      send(false, 500, 2);
      flows.expire(consume, true);
      check(outbound == "abcdef" && inbound == std::string("x\0y", 3));
      check(kinds.front() == Kind::flow_open && kinds.back() == Kind::flow_close);
      check(std::ranges::count(kinds, Kind::flow_gap) == 0);
    }
  }

  void passiveGaps(ConcurrentMemory& memory) {
    TcpFlows flows{memory};
    std::string output;
    std::size_t gaps = 0;
    traffic::Direction gap_direction = traffic::Direction::outbound;
    auto emit = [&](const traffic::Event& event) {
      const auto flow = FlowCodec::decode(event.bytes);

      if (event.kind == Kind::flow_gap) {
        ++gaps;
        gap_direction = flow.direction;
      }

      if (event.kind == Kind::stream_data) {
        output.append(reinterpret_cast<const char*>(flow.bytes.data()), flow.bytes.size());
      }
    };

    auto send = [&](bool incoming, std::uint32_t sequence, Byte flags, std::string_view bytes = {}) {
      const auto packet = tcp(false, incoming, sequence, flags, bytes);

      flows.packet(traffic::Event{.link_type = DLT_RAW, .original_bytes = static_cast<std::uint32_t>(packet.size()), .bytes = packet}, emit);
    };

    send(false, 0, 2);
    send(false, 4, 16, "def");
    send(false, 1, 16, "abcde");
    check(output == "abcdef" && gaps == 0);
    send(true, 9, 18);
    send(true, 14, 16, "later");
    send(false, 7, 4);
    check(gaps == 1 && gap_direction == traffic::Direction::inbound);
    send(false, 0, 2);
    send(false, 4, 16, "wrong");
    send(false, 1, 16, "abcde");
    check(gaps == 2 && output == "abcdef");
    send(false, 0, 2);
    const std::string large(40000, 'x');

    send(false, 2, 16, large);
    send(false, 50000, 16, large);
    check(gaps == 3 && output == "abcdef");
  }

  void applicationDetection(ConcurrentMemory& memory) {
    for (const bool fragmented : {false, true}) {
      ProxyCaptureLimits limits;

      limits.enabled = true;
      CaptureProducer captures{memory, limits};
      ProxyCounters counters;
      ApplicationRelay relay{memory, ConnectionObservation{counters, &captures, 31}, "fixture.test"};
      TestByteStream child, origin;

      child.input = "GET /plain HTTP/1.1\r\nHost: fixture.test\r\n\r\n";
      child.read_limit = fragmented ? 1 : 65536;
      origin.visible = 0;
      for (std::size_t round = 0; round < 1024 && origin.output != child.input; ++round) {
        relay.advance(child, origin, TunnelReadiness::available(), nullptr);
      }

      check(origin.output == child.input);
      origin.input = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n" + std::string("x\0y", 3);
      origin.visible = origin.input.size();
      origin.read_limit = fragmented ? 1 : 65536;
      for (std::size_t round = 0; round < 1024 && child.output != origin.input; ++round) {
        relay.advance(child, origin, TunnelReadiness::available(), nullptr);
      }

      check(child.output == origin.input);
      auto request = captures.tryReceive();
      auto response = captures.tryReceive();

      check(request && response && (*request)->key.connection == 31 && (*response)->status_code == 200);
      check((*request)->method() == "GET" && (*request)->target() == "/plain");
      check(std::ranges::equal((*response)->body.bytes(), std::string_view("x\0y", 3)));
    }
  }

  // What the relay makes of a plain connection's first bytes: the origin receives them unchanged
  // whatever they are, and only HTTP is captured as HTTP.
  void protocolSniffing(ConcurrentMemory& memory) {
    struct Sniffed {
      std::string forwarded;
      std::vector<CaptureProtocol> captured;
    };

    auto relayed = [&](const std::string& request, const std::string& response) {
      ProxyCaptureLimits limits;

      limits.enabled = true;
      CaptureProducer captures{memory, limits};
      ProxyCounters counters;
      Sniffed sniffed;

      {
        ApplicationRelay relay{memory, ConnectionObservation{counters, &captures, 32}, "fixture.test"};
        TestByteStream child, origin;

        child.input = request;
        child.read_limit = 1000;
        origin.visible = 0;
        for (std::size_t round = 0; round < 4096 && origin.output != child.input; ++round) {
          relay.advance(child, origin, TunnelReadiness::available(), nullptr);
        }

        origin.input = response;
        origin.visible = response.size();
        for (std::size_t round = 0; round < 4096 && child.output != origin.input; ++round) {
          relay.advance(child, origin, TunnelReadiness::available(), nullptr);
        }

        check(child.output == response);
        sniffed.forwarded = origin.output;
      }

      while (const auto half = captures.tryReceive()) {
        sniffed.captured.push_back((*half)->protocol);
      }

      return sniffed;
    };

    constexpr std::array<std::pair<std::string_view, std::string_view>, 4> request_fields{{
        {":method", "GET"},
        {":scheme", "http"},
        {":authority", "fixture.test"},
        {":path", "/prior-knowledge"},
    }};
    constexpr std::array<std::pair<std::string_view, std::string_view>, 1> response_fields{{{":status", "200"}}};
    const auto http2 = std::string{Http2DirectionObserver<SystemAllocator>::client_preface} + http2Frame(Http2FrameKind::settings, 0, 0, {}) + http2Frame(Http2FrameKind::headers, 5, 1, hpackFields(request_fields));
    const auto prior = relayed(http2, http2Frame(Http2FrameKind::settings, 0, 0, {}) + http2Frame(Http2FrameKind::headers, 5, 1, hpackFields(response_fields)));

    check(prior.forwarded == http2 && !prior.captured.empty());
    check(std::ranges::all_of(prior.captured, [](CaptureProtocol protocol) {
      return protocol == CaptureProtocol::http2;
    }));

    const auto binary = std::string{"GET /\0binary", 13};
    const auto opaque = relayed(binary, "reply");

    check(opaque.forwarded == binary && opaque.captured.empty());

    std::string unterminated = "GET /";

    unterminated.resize(StreamPrefix::capacity, 'a');
    unterminated += "\r\n\r\nafter the prefix";
    const auto filled = relayed(unterminated, "reply");

    check(filled.forwarded == unterminated && filled.captured.empty());
  }

  const telar::testing::Case case_protocol_sniffing{
      "traffic_flow.protocol_sniffing",
      [] {
        SystemAllocator system;
        MemoryAdapter adapter{system};
        ConcurrentMemory& memory = adapter;

        protocolSniffing(memory);
      },
  };
  const telar::testing::Case case_gates{
      "traffic_flow.gates",
      [] {
        SystemAllocator system;
        MemoryAdapter adapter{system};
        ConcurrentMemory& memory = adapter;

        gates(memory);
      },
  };
  const telar::testing::Case case_composition{
      "traffic_flow.composition",
      [] {
        SystemAllocator system;
        MemoryAdapter adapter{system};
        ConcurrentMemory& memory = adapter;

        composition(memory);
      },
  };
  const telar::testing::Case case_application_detection{
      "traffic_flow.application_detection",
      [] {
        SystemAllocator system;
        MemoryAdapter adapter{system};
        ConcurrentMemory& memory = adapter;

        applicationDetection(memory);
      },
  };
  const telar::testing::Case case_reconstruction{
      "traffic_flow.reconstruction",
      [] {
        SystemAllocator system;
        MemoryAdapter adapter{system};
        ConcurrentMemory& memory = adapter;

        reconstruction(memory);
      },
  };
  const telar::testing::Case case_passive_gaps{
      "traffic_flow.passive_gaps",
      [] {
        SystemAllocator system;
        MemoryAdapter adapter{system};
        ConcurrentMemory& memory = adapter;

        passiveGaps(memory);
      },
  };

}
