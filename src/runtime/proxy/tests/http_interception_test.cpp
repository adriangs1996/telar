#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <zstd.h>

import std;
import telar.base.memory.allocators;
import telar.base.memory.sensitive;
import telar.platform.primitives;
import telar.testing;
import telar.testing.test_byte_stream;
import telar.runtime.proxy.intercepted_relay;
import telar.runtime.proxy.runtime;
import telar.wire.vocabulary;
import telar.runtime.http.message;
import telar.runtime.http1.head;
import telar.runtime.proxy.http2_capture_streams;
import telar.runtime.traffic.control_protocol;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::traffic;
  using telar::Byte;

  namespace {
    struct HttpOwner final : HttpControl {
      ConcurrentMemory& memory;
      bool fail_closed = true;
      bool observe_response = true;
      std::vector<Byte> input, replacement;
      std::vector<std::string> errors;
      std::uint64_t next = 0, ticket = 0;
      Verdict answer = Verdict::pending;
      traffic::Direction direction = traffic::Direction::outbound;

      explicit HttpOwner(ConcurrentMemory& memory)
          : memory(memory) {}

      HttpPolicy policy(const FlowEvent& event) noexcept override {
        return {observe_response || event.direction == traffic::Direction::outbound, fail_closed};
      }

      std::uint64_t interceptHttp(const FlowEvent& event) noexcept override {
        check(ticket == 0);
        input.assign(event.bytes.begin(), event.bytes.end());
        direction = event.direction;
        answer = Verdict::pending;
        return ticket = ++next;
      }

      FlowControl::Decision pollHttp(std::uint64_t id, std::span<Byte> bytes) noexcept override {
        check(ticket == id);
        if (answer == Verdict::pending) {
          return {answer};
        }

        check(replacement.size() <= bytes.size());
        std::ranges::copy(replacement, bytes.begin());
        ticket = 0;
        return {answer, replacement.size()};
      }

      void cancelHttp(std::uint64_t id) noexcept override {
        check(ticket == id);
        ticket = 0;
      }

      auto httpDeadline(std::uint64_t) noexcept -> ds::Option<FlowControl::Time> override {
        return std::chrono::steady_clock::now() + std::chrono::seconds{1};
      }

      void httpUnavailable(const FlowEvent& event) noexcept override {
        errors.emplace_back(event.reason);
      }

      void replace(std::span<const Byte> bytes, std::string_view target = {}, std::string_view method = {}) {
        auto view = HttpMessageCodec::decode(input);

        view.body = bytes;
        if (!target.empty()) {
          view.target = target;
        }

        if (!method.empty()) {
          view.method = method;
        }

        SensitiveAllocation output{memory, HttpMessageLimits::message_bytes};
        const auto encoded = HttpMessageCodec::encode(output.bytesMut(), view);

        replacement.assign(encoded.begin(), encoded.end());
        answer = Verdict::replace;
      }
    };

    using Connection = Http1Connection<IgnoreHttp1Capture>;

    template <typename Predicate>
    void pump(Connection& connection, TestByteStream& child, TestByteStream& origin, Predicate&& done, std::source_location location = std::source_location::current()) {
      for (unsigned attempt = 0; attempt < 100000 && !done(); ++attempt) {
        connection.advance(child, origin, TunnelReadiness::available());
      }

      check(done(), location);
    }

    struct Parsed {
      std::vector<Byte> bytes;
      std::vector<std::string> trailers;

      void headStarted() noexcept {}

      void head(std::string_view) noexcept {}

      void payload(std::span<const Byte> body) noexcept {
        bytes.insert(bytes.end(), body.begin(), body.end());
      }

      void trailer(std::string_view line) noexcept {
        trailers.emplace_back(line);
      }

      void lineTooLong(Http1Line) noexcept {
        check(false);
      }
    };

    void editing(ConcurrentMemory& memory) {
      HttpOwner owner{memory};
      ProxyCounters counters;
      Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 7, .host = "fixture.test"})}};
      TestByteStream child, origin;

      child.input = "POST /original HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 3\r\n\r\n" + std::string{"a\0b", 3};
      child.read_limit = 1;
      origin.visible = 0;
      origin.write_limit = 3;
      origin.alternating_writes = true;
      pump(connection, child, origin, [&] {
        return owner.ticket != 0;
      });

      check(origin.output.empty() && owner.direction == traffic::Direction::outbound);
      check(HttpMessageCodec::decode(owner.input).body.size() == 3);
      const std::array<Byte, 7> changed{'c', 'h', 0, 'a', 'n', 'g', 'e'};

      owner.replace(changed, "/edited");
      pump(connection, child, origin, [&] {
        return origin.output.ends_with(std::string{"ch\0ange", 7});
      });

      check(origin.output.starts_with("POST /edited HTTP/1.1\r\n") && origin.output.contains("Content-Length: 7\r\n"));
      origin.input = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nold";
      origin.visible = origin.input.size();
      pump(connection, child, origin, [&] {
        return owner.ticket != 0;
      });

      check(child.output.empty() && owner.direction == traffic::Direction::inbound);
      owner.replace(changed);
      pump(connection, child, origin, [&] {
        return child.output.ends_with(std::string{"ch\0ange", 7});
      });

      check(child.output.contains("Content-Length: 7\r\n") && owner.errors.empty());
    }

    void compressedTrailers(ConcurrentMemory& memory) {
      HttpOwner owner{memory};
      ProxyCounters counters;
      Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 8, .host = "fixture.test"})}};
      HttpMessage message{memory};

      message.method = "POST";
      message.target = "/gzip";
      message.headers.append("Host", "fixture.test");
      message.headers.append("Content-Encoding", "gzip");
      message.trailers.append("X-Checksum", "fixture");
      const std::array<Byte, 3> before{'a', 0, 'b'};

      message.body.assign(before.begin(), before.end());
      const auto wire = message.serializeHttp1();
      TestByteStream child, origin;

      child.input.assign(reinterpret_cast<const char*>(wire.data()), wire.size());
      child.read_limit = 1;
      origin.visible = 0;
      pump(connection, child, origin, [&] {
        return owner.ticket != 0;
      });

      const auto view = HttpMessageCodec::decode(owner.input);

      check(view.trailer_count == 1 && view.trailers[0].name == "X-Checksum" && std::ranges::equal(view.body, before));
      const std::array<Byte, 9> after{'e', 'x', 'p', 0, 'a', 'n', 'd', 'e', 'd'};

      owner.replace(after);
      pump(connection, child, origin, [&] {
        return connection.inflight() == 1 && owner.ticket == 0 && origin.output.ends_with("0\r\nX-Checksum: fixture\r\n\r\n");
      });

      TestByteStream source, sink;

      source.input = origin.output;
      Parsed parsed;
      Http1MessageRelay relay;

      for (unsigned attempt = 0; attempt < 4096 && relay.state() != Http1MessageRelay::State::complete; ++attempt) {
        relay.advance(source, sink, parsed);
      }

      check(relay.state() == Http1MessageRelay::State::complete && parsed.trailers.size() == 1);
      check(std::ranges::equal(HttpContentCodec{memory}.decode(parsed.bytes, "gzip", 1024).bytes(), after));
    }

    void expectContinue(ConcurrentMemory& memory) {
      HttpOwner owner{memory};
      ProxyCounters counters;
      Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 9, .host = "fixture.test"})}};
      TestByteStream child, origin;

      child.input = "POST /expect HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n";
      child.write_limit = 1;
      child.alternating_writes = true;
      origin.visible = 0;
      pump(connection, child, origin, [&] {
        return child.output == "HTTP/1.1 100 Continue\r\n\r\n";
      });

      check(origin.output.empty() && owner.ticket == 0);
      child.input += "abc";
      pump(connection, child, origin, [&] {
        return owner.ticket != 0;
      });

      owner.answer = Verdict::allow;
      pump(connection, child, origin, [&] {
        return origin.output.ends_with("\r\n\r\nabc");
      });

      check(!origin.output.contains("Expect:") && owner.errors.empty());
    }

    void headResponse(ConcurrentMemory& memory) {
      HttpOwner owner{memory};
      ProxyCounters counters;
      Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 11, .host = "fixture.test"})}};
      TestByteStream child, origin;

      child.input = "HEAD /metadata HTTP/1.1\r\nHost: fixture.test\r\n\r\n";
      origin.visible = 0;
      pump(connection, child, origin, [&] {
        return owner.ticket != 0;
      });

      owner.answer = Verdict::allow;
      pump(connection, child, origin, [&] {
        return origin.output == child.input;
      });

      origin.input = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 256\r\n\r\n";
      origin.visible = origin.input.size();
      pump(connection, child, origin, [&] {
        return owner.ticket != 0;
      });

      const auto view = HttpMessageCodec::decode(owner.input);

      check(view.response_to_head && view.body.empty());
      owner.answer = Verdict::allow;
      pump(connection, child, origin, [&] {
        return child.output == origin.input;
      });

      check(owner.errors.empty());
    }

    void invalidFraming(ConcurrentMemory& memory) {
      for (const std::string_view body : {"+0\r\n\r\n", "1_0\r\n0123456789abcdef\r\n0\r\n\r\n", "1\r\nx!!0\r\n\r\n", "0\r\r\n\r\n"}) {
        HttpOwner owner{memory};
        ProxyCounters counters;
        Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 12, .host = "fixture.test"})}};
        TestByteStream child, origin;

        child.input = "POST /invalid HTTP/1.1\r\nHost: fixture.test\r\nTransfer-Encoding: chunked\r\n\r\n" + std::string{body};
        origin.visible = 0;
        pump(connection, child, origin, [&] {
          return connection.finished();
        });

        check(origin.output.empty() && owner.ticket == 0 && !owner.errors.empty());
      }
    }

    void incompleteMessage(ConcurrentMemory& memory) {
      for (const bool closed : {false, true}) {
        HttpOwner owner{memory};

        owner.fail_closed = closed;
        ProxyCounters counters;
        Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 13, .host = "fixture.test"})}};
        TestByteStream child, origin;

        child.input = "POST /incomplete HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 8\r\n\r\nabc";
        child.ended = true;
        origin.visible = 0;
        origin.write_limit = 3;
        origin.alternating_writes = true;
        pump(connection, child, origin, [&] {
          return connection.finished();
        });

        check(owner.ticket == 0 && owner.errors == std::vector<std::string>{"http_incomplete_message"});
        check(closed ? origin.output.empty() : origin.output == child.input);
      }
    }

    void headMethods(ConcurrentMemory& memory) {
      for (const bool original_head : {false, true}) {
        for (const bool observe_response : {false, true}) {
          HttpOwner owner{memory};

          owner.observe_response = observe_response;
          ProxyCounters counters;
          Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 14, .host = "fixture.test"})}};
          TestByteStream child, origin;

          child.input = std::string{original_head ? "HEAD" : "GET"} + " /method HTTP/1.1\r\nHost: fixture.test\r\n\r\n";
          origin.visible = 0;
          pump(connection, child, origin, [&] {
            return owner.ticket != 0;
          });

          owner.replace({}, {}, original_head ? "GET" : "HEAD");
          pump(connection, child, origin, [&] {
            return origin.output.ends_with("\r\n\r\n");
          });

          origin.input = original_head ? "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc" : "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 256\r\n\r\n";
          origin.visible = origin.input.size();
          if (observe_response) {
            pump(connection, child, origin, [&] {
              return owner.ticket != 0;
            });

            owner.answer = Verdict::allow;
          }

          pump(connection, child, origin, [&] {
            const auto boundary = child.output.find("\r\n\r\n");
            if (boundary == std::string::npos) {
              return false;
            }

            const auto head = Http1Head::analyze(std::string_view{child.output}.substr(0, boundary + 4), true, original_head);

            return head && child.output.size() == boundary + 4 + head->framing.length;
          });

          TestByteStream source, sink;

          source.input = child.output;
          Parsed parsed;
          Http1MessageRelay relay;

          relay.reset(true, original_head);
          for (unsigned attempt = 0; attempt < 4096 && relay.state() != Http1MessageRelay::State::complete; ++attempt) {
            relay.advance(source, sink, parsed);
          }

          check(relay.state() == Http1MessageRelay::State::complete && source.offset == source.input.size());
          if (original_head) {
            check(parsed.bytes.empty());
          } else {
            check(HttpContentCodec{memory}.decode(parsed.bytes, "gzip", 1024).size == 0);
          }
        }
      }
    }

    void limits(ConcurrentMemory& memory) {
      for (const bool closed : {false, true}) {
        HttpOwner owner{memory};

        owner.fail_closed = closed;
        ProxyCounters counters;
        Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 10, .host = "fixture.test"})}};
        TestByteStream child, origin;
        const std::string body(HttpMessageLimits::body_bytes + Http1Head::capacity + 1, 'x');

        child.input = "POST /limit HTTP/1.1\r\nHost: fixture.test\r\nTransfer-Encoding: chunked\r\n\r\n";
        std::array<char, 32> size;
        const auto formatted = std::to_chars(size.data(), size.data() + size.size(), body.size(), 16);

        child.input.append(size.data(), formatted.ptr);
        child.input += "\r\n" + body + "\r\n0\r\n\r\n";
        child.read_limit = 16384;
        origin.visible = 0;
        origin.write_limit = 4096;
        origin.alternating_writes = true;
        pump(connection, child, origin, [&] {
          return closed ? connection.finished() : origin.output.size() == child.input.size();
        });

        check(owner.ticket == 0 && !owner.errors.empty());
        check(closed ? origin.output.empty() : origin.output == child.input);
      }
    }

    // A hook's reject closes the exchange and is reported, as an HTTP/2 stream's is.
    void rejected(ConcurrentMemory& memory) {
      HttpOwner owner{memory};
      ProxyCounters counters;
      Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 12, .host = "fixture.test"})}};
      TestByteStream child, origin;

      child.input = "POST /reject HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 6\r\n\r\nsecret";
      pump(connection, child, origin, [&] {
        return owner.ticket != 0;
      });

      owner.answer = Verdict::reject;
      pump(connection, child, origin, [&] {
        return connection.finished();
      });

      check(owner.ticket == 0 && origin.output.empty());
      check(owner.errors == std::vector<std::string>{"http_interception_rejected"});
    }

    // A head the lax framing parser accepts but the strict one refuses is where smuggling lives:
    // closed, nothing reaches the origin; open, the original bytes pass untouched.
    void invalidHeadPolicy(ConcurrentMemory& memory) {
      for (const bool closed : {false, true}) {
        HttpOwner owner{memory};

        owner.fail_closed = closed;
        ProxyCounters counters;
        Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 15, .host = "fixture.test"})}};
        TestByteStream child, origin;

        child.input = "GET /duplicate HTTP/1.1\r\nHost: fixture.test\r\nHost: other.test\r\n\r\n";
        origin.visible = 0;
        pump(connection, child, origin, [&] {
          return closed ? connection.finished() : origin.output == child.input;
        });

        check(owner.ticket == 0 && owner.errors == std::vector<std::string>{"http_invalid_head"});
        check(closed ? origin.output.empty() : origin.output == child.input);
      }
    }

    // A third-party plugin's replacement that does not decode, or that names a method no HTTP/1
    // peer accepts, fails the exchange instead of reaching the origin in part.
    void invalidDecision(ConcurrentMemory& memory) {
      for (const bool truncated : {false, true}) {
        HttpOwner owner{memory};
        ProxyCounters counters;
        Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 16, .host = "fixture.test"})}};
        TestByteStream child, origin;

        child.input = "POST /decision HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 6\r\n\r\nsecret";
        origin.visible = 0;
        pump(connection, child, origin, [&] {
          return owner.ticket != 0;
        });

        if (truncated) {
          owner.replace({});
          owner.replacement.pop_back();
        } else {
          owner.replace({}, {}, "BAD METHOD");
        }

        pump(connection, child, origin, [&] {
          return connection.finished();
        });

        check(origin.output.empty() && owner.errors == std::vector<std::string>{"http_invalid_decision"});
      }
    }

    // Chunk extensions cost wire bytes without adding body: a body far under its limit can still
    // carry a wire past the buffer's bound, which is refused instead of buffered.
    void chunkFramingAmplification(ConcurrentMemory& memory) {
      const std::string chunk = "1;" + std::string(1000, 'e') + "\r\nx\r\n";
      constexpr std::size_t wire_bound = HttpMessageLimits::body_bytes + 2 * Http1Head::capacity;
      const auto chunks = wire_bound / chunk.size() + 16;

      for (const bool closed : {false, true}) {
        HttpOwner owner{memory};

        owner.fail_closed = closed;
        ProxyCounters counters;
        Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 17, .host = "fixture.test"})}};
        TestByteStream child, origin;

        child.input = "POST /extensions HTTP/1.1\r\nHost: fixture.test\r\nTransfer-Encoding: chunked\r\n\r\n";
        for (std::size_t index = 0; index < chunks; ++index) {
          child.input += chunk;
        }

        child.input += "0\r\n\r\n";
        check(chunks < HttpMessageLimits::body_bytes);
        child.read_limit = 16384;
        origin.visible = 0;
        origin.write_limit = 4096;
        origin.alternating_writes = true;
        pump(connection, child, origin, [&] {
          return closed ? connection.finished() : origin.output.size() == child.input.size();
        });

        check(owner.ticket == 0 && owner.errors == std::vector<std::string>{"http_wire_limit"});
        check(closed ? origin.output.empty() : origin.output == child.input);
      }
    }

    // Trailers come from the peer like any field: one without a colon or with an invalid name is
    // refused, not written again unchecked.
    void invalidTrailers(ConcurrentMemory& memory) {
      for (const std::string_view trailer : {"NoColon", "Bad Name: x"}) {
        HttpOwner owner{memory};
        ProxyCounters counters;
        Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 18, .host = "fixture.test"})}};
        TestByteStream child, origin;

        child.input = "POST /trailers HTTP/1.1\r\nHost: fixture.test\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n" + std::string{trailer} + "\r\n\r\n";
        origin.visible = 0;
        pump(connection, child, origin, [&] {
          return connection.finished();
        });

        check(owner.ticket == 0 && origin.output.empty() && owner.errors == std::vector<std::string>{"http_invalid_trailer"});
      }
    }

    // A declared length past the buffer is settled from the head alone: closed, the origin gets
    // nothing and the client need not send the body; open, the head reaches the origin before any
    // body byte exists.
    void contentLengthOverLimit(ConcurrentMemory& memory) {
      for (const bool closed : {false, true}) {
        HttpOwner owner{memory};

        owner.fail_closed = closed;
        ProxyCounters counters;
        Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 19, .host = "fixture.test"})}};
        TestByteStream child, origin;

        child.input = "POST /large HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: " + std::to_string(2 * HttpMessageLimits::body_bytes) + "\r\n\r\nabc";
        origin.visible = 0;
        pump(connection, child, origin, [&] {
          return closed ? connection.finished() : origin.output == child.input;
        });

        check(owner.ticket == 0 && owner.errors == std::vector<std::string>{"http_body_limit"});
        check(closed ? origin.output.empty() : origin.output == child.input);
      }
    }

    // An event stream has no end to wait for: an intercepted one reaches the client event by event,
    // with the reason reported.
    void eventStreamResponse(ConcurrentMemory& memory) {
      HttpOwner owner{memory};

      owner.fail_closed = false;
      ProxyCounters counters;
      Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 20, .host = "fixture.test"})}};
      TestByteStream child, origin;

      child.input = "GET /events HTTP/1.1\r\nHost: fixture.test\r\n\r\n";
      origin.visible = 0;
      pump(connection, child, origin, [&] {
        return owner.ticket != 0;
      });

      owner.answer = Verdict::allow;
      pump(connection, child, origin, [&] {
        return origin.output == child.input;
      });

      origin.input = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: first\n\n";
      origin.visible = origin.input.size();
      pump(connection, child, origin, [&] {
        return child.output == origin.input;
      });

      check(!origin.ended && owner.ticket == 0 && owner.errors == std::vector<std::string>{"http_streaming_body"});
    }

    // Only 100-continue is understood: another expectation gets no interim response, and the request
    // passes unchanged when open and not at all when closed.
    void unsupportedExpectation(ConcurrentMemory& memory) {
      for (const bool closed : {false, true}) {
        HttpOwner owner{memory};

        owner.fail_closed = closed;
        ProxyCounters counters;
        Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 21, .host = "fixture.test"})}};
        TestByteStream child, origin;

        child.input = "POST /expect HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 3\r\nExpect: foo\r\n\r\nabc";
        origin.visible = 0;
        pump(connection, child, origin, [&] {
          return closed ? connection.finished() : origin.output == child.input;
        });

        check(child.output.empty() && owner.ticket == 0 && owner.errors == std::vector<std::string>{"http_unsupported_expectation"});
        check(closed ? origin.output.empty() : origin.output == child.input);
      }
    }

    // A chunk-size line past the line limit fails the intercepted message: closed, the origin gets
    // none of it.
    void chunkLineLimit(ConcurrentMemory& memory) {
      HttpOwner owner{memory};
      ProxyCounters counters;
      Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, traffic::FlowIdentity::of({.id = 22, .host = "fixture.test"})}};
      TestByteStream child, origin;

      child.input = "POST /line HTTP/1.1\r\nHost: fixture.test\r\nTransfer-Encoding: chunked\r\n\r\n1;" + std::string(2048, 'e') + "\r\nx\r\n0\r\n\r\n";
      origin.visible = 0;
      pump(connection, child, origin, [&] {
        return connection.finished();
      });

      check(owner.ticket == 0 && origin.output.empty() && owner.errors == std::vector<std::string>{"http_line_limit"});
    }
  }

  void testHttpInterception() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;

    rejected(memory);
    editing(memory);
    compressedTrailers(memory);
    expectContinue(memory);
    headResponse(memory);
    invalidFraming(memory);
    incompleteMessage(memory);
    headMethods(memory);
    limits(memory);
  }

  template <void (*body)(ConcurrentMemory&)>
  void withMemory() {
    SystemAllocator system;
    MemoryAdapter adapter{system};

    body(adapter);
  }

  const telar::testing::Case case_http_interception{"http_interception.http_interception", testHttpInterception};
  const telar::testing::Case case_invalid_head_policy{"http_interception.invalid_head_policy", withMemory<invalidHeadPolicy>};
  const telar::testing::Case case_invalid_decision{"http_interception.invalid_decision", withMemory<invalidDecision>};
  const telar::testing::Case case_chunk_framing_amplification{"http_interception.chunk_framing_amplification", withMemory<chunkFramingAmplification>};
  const telar::testing::Case case_invalid_trailers{"http_interception.invalid_trailers", withMemory<invalidTrailers>};
  const telar::testing::Case case_content_length_over_limit{"http_interception.content_length_over_limit", withMemory<contentLengthOverLimit>};
  const telar::testing::Case case_event_stream_response{"http_interception.event_stream_response", withMemory<eventStreamResponse>};
  const telar::testing::Case case_unsupported_expectation{"http_interception.unsupported_expectation", withMemory<unsupportedExpectation>};
  const telar::testing::Case case_chunk_line_limit{"http_interception.chunk_line_limit", withMemory<chunkLineLimit>};

}
