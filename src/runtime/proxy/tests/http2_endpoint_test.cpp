#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <nghttp2/nghttp2.h>
#include <zstd.h>

import std;
import telar.base.memory.allocators;
import telar.base.memory.sensitive;
import telar.testing;
import telar.testing.test_memory;
import telar.testing.test_byte_stream;
import telar.runtime.proxy.runtime;
import telar.runtime.traffic.control_backend;
import telar.vocabulary;
import telar.runtime.http.message;
import telar.runtime.traffic.control_protocol;
import telar.runtime.proxy.http2_capture_streams;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::traffic;
  using telar::Byte;

  namespace {
    struct Owner : HttpControl {
      ConcurrentMemory& memory;
      Interception<HttpMessageLimits::message_bytes> broker;

      struct Request {
        std::uint64_t ticket;
        std::vector<Byte> bytes;
      };

      std::vector<Request> requests;
      std::vector<std::string> errors;

      Owner(ConcurrentMemory& memory, bool fail_closed = true, std::string_view host = "fixture.test", std::uint32_t timeout_ms = 5000)
          : memory(memory),
            broker(memory) {
        broker.configure({.host = host, .visibility = 3, .timeout_ms = timeout_ms, .fail_closed = fail_closed});
      }

      HttpPolicy policy(const FlowEvent& event) noexcept override {
        return broker.policy(event);
      }

      std::uint64_t interceptHttp(const FlowEvent& event) noexcept override {
        return broker.begin(event);
      }

      FlowControl::Decision pollHttp(std::uint64_t ticket, std::span<Byte> output) noexcept override {
        return broker.poll(ticket, output);
      }

      void cancelHttp(std::uint64_t ticket) noexcept override {
        broker.cancel(ticket);
      }

      ds::Option<FlowControl::Time> httpDeadline(std::uint64_t ticket) noexcept override {
        return broker.deadline(ticket);
      }

      void httpUnavailable(const FlowEvent& event) noexcept override {
        errors.emplace_back(event.reason);
      }

      void collect() {
        broker.deliver(1, [&](const FlowEvent& event) {
          requests.push_back({event.ticket, {event.bytes.begin(), event.bytes.end()}});
          return true;
        });
      }

      void answer(const Request& request, bool edit = true) {
        auto message = HttpMessageCodec::decode(request.bytes);

        if (!edit) {
          broker.decide(request.ticket, Verdict::allow, {});
          return;
        }

        const auto prefix = message.response ? std::string{"response\0", 9} : std::string{"request\0", 8};
        auto body = prefix + std::string{reinterpret_cast<const char*>(message.body.data()), message.body.size()};

        message.body = {reinterpret_cast<const Byte*>(body.data()), body.size()};
        const auto path = std::string{"/edited"} + std::string{message.target};

        if (!message.response) {
          message.target = path;
        }

        if (!message.response && path == "/edited/be-head") {
          message.method = "HEAD";
        }

        if (!message.response && path == "/edited/be-get") {
          message.method = "GET";
        }

        if (message.response) {
          message.status = 202;
        }

        SensitiveAllocation output{memory, HttpMessageLimits::message_bytes};

        broker.decide(request.ticket, Verdict::replace, HttpMessageCodec::encode(output.bytesMut(), message));
      }
    };

    class Peer {
    public:
      using Fields = std::vector<std::pair<std::string, std::string>>;

      struct Stream {
        std::vector<std::pair<std::string, std::string>> headers;
        Fields trailers;
        std::string body, outgoing;
        std::size_t sent = 0;
        bool complete = false, responded = false;
        std::uint32_t reset = 0;

        auto field(std::string_view name) const -> std::string_view {
          for (const auto& field : headers) {
            if (field.first == name) {
              return field.second;
            }
          }

          return {};
        }
      };

      explicit Peer(bool server) {
        nghttp2_session_callbacks* callbacks = nullptr;

        check(nghttp2_session_callbacks_new(&callbacks) == 0);
        nghttp2_session_callbacks_set_on_header_callback(callbacks, &header);
        nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, &data);
        nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, &frame);
        nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, &closed);
        check((server ? nghttp2_session_server_new(&session_, callbacks, this) : nghttp2_session_client_new(&session_, callbacks, this)) == 0);
        nghttp2_session_callbacks_del(callbacks);
        check(nghttp2_submit_settings(session_, NGHTTP2_FLAG_NONE, nullptr, 0) == 0);
      }

      ~Peer() {
        nghttp2_session_del(session_);
      }

      Peer(const Peer&) = delete;
      Peer& operator=(const Peer&) = delete;

      auto request(std::string_view path, std::string body, std::string_view method = "POST") -> std::int32_t {
        const auto id = nghttp2_session_get_next_stream_id(session_);
        auto& stream = streams[id];

        stream.outgoing = std::move(body);
        const ds::Array<std::pair<std::string_view, std::string_view>, 4> fields{{{":method", method}, {":scheme", "https"}, {":authority", "fixture.test"}, {":path", path}}};
        const auto native = nativeFields(fields);
        const nghttp2_data_provider2 provider{.source = {.ptr = &stream}, .read_callback = &read};

        check(nghttp2_submit_request2(session_, nullptr, native.data(), native.size(), &provider, nullptr) == static_cast<std::int32_t>(id));
        return static_cast<std::int32_t>(id);
      }

      // A request with exactly `fields`, as a client that sends what it likes would.
      auto request(const Fields& fields, std::string body) -> std::int32_t {
        const auto id = nghttp2_session_get_next_stream_id(session_);
        auto& stream = streams[id];

        stream.outgoing = std::move(body);
        const auto native = nativeFields(fields);
        const nghttp2_data_provider2 provider{.source = {.ptr = &stream}, .read_callback = &read};

        check(nghttp2_submit_request2(session_, nullptr, native.data(), native.size(), &provider, nullptr) == static_cast<std::int32_t>(id));
        return static_cast<std::int32_t>(id);
      }

      // A response with exactly `fields`, then `body` and, when given, `trailers`.
      void respond(std::int32_t id, const Fields& fields, std::string body, Fields trailers = {}) {
        auto& stream = streams.at(id);

        stream.outgoing = std::move(body);
        stream.trailers = std::move(trailers);
        stream.sent = 0;
        stream.responded = true;
        const auto native = nativeFields(fields);
        const nghttp2_data_provider2 provider{.source = {.ptr = &stream}, .read_callback = &read};

        check(nghttp2_submit_response2(session_, id, native.data(), native.size(), &provider) == 0);
      }

      void respond(std::int32_t id, std::string body) {
        auto& stream = streams.at(id);

        stream.outgoing = std::move(body);
        stream.sent = 0;
        stream.responded = true;
        const auto length = std::to_string(stream.outgoing.size());
        const ds::Array<std::pair<std::string_view, std::string_view>, 2> fields{{{":status", "200"}, {"content-length", length}}};
        const auto native = nativeFields(fields);
        const nghttp2_data_provider2 provider{.source = {.ptr = &stream}, .read_callback = &read};

        check(nghttp2_submit_response2(session_, id, native.data(), native.size(), stream.field(":method") == "HEAD" ? nullptr : &provider) == 0);
      }

      void echo() {
        for (auto& [id, stream] : streams) {
          if (echoing && stream.complete && !stream.responded && !stream.reset) {
            respond(id, std::string{"origin\0", 7} + stream.body);
          }
        }
      }

      // An informational response, which precedes the final one on the same stream.
      void inform(std::int32_t id, const Fields& fields) {
        const auto native = nativeFields(fields);

        check(nghttp2_submit_headers(session_, NGHTTP2_FLAG_NONE, id, nullptr, native.data(), native.size(), nullptr) >= 0);
      }

      void ping() {
        constexpr ds::Array<std::uint8_t, 8> bytes{1, 2, 3, 4, 5, 6, 7, 8};

        check(nghttp2_submit_ping(session_, 0, bytes.data()) == 0);
      }

      void reset(std::int32_t id) {
        check(nghttp2_submit_rst_stream(session_, 0, id, NGHTTP2_CANCEL) == 0);
      }

      void goaway(std::int32_t last) {
        check(nghttp2_submit_goaway(session_, 0, last, NGHTTP2_NO_ERROR, nullptr, 0) == 0);
      }

      void send(TestByteStream& transport) {
        for (unsigned count = 0; count < 128; ++count) {
          const std::uint8_t* bytes = nullptr;
          const auto size = nghttp2_session_mem_send2(session_, &bytes);

          check(size >= 0);
          if (!size) {
            return;
          }

          transport.input.append(reinterpret_cast<const char*>(bytes), static_cast<std::size_t>(size));
        }
      }

      void receive(TestByteStream& transport) {
        const auto bytes = std::string_view{transport.output}.substr(received_);
        if (bytes.empty()) {
          return;
        }

        const auto count = nghttp2_session_mem_recv2(session_, reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size());

        check(count >= 0 && static_cast<std::size_t>(count) == bytes.size());
        received_ += bytes.size();
      }

      std::map<std::int32_t, Stream> streams;
      bool pong = false;
      bool echoing = true;

    private:
      static auto nativeFields(const Fields& fields) -> std::vector<nghttp2_nv> {
        std::vector<nghttp2_nv> native;

        for (const auto& [name, value] : fields) {
          native.push_back({reinterpret_cast<std::uint8_t*>(const_cast<char*>(name.data())), reinterpret_cast<std::uint8_t*>(const_cast<char*>(value.data())), name.size(), value.size(), NGHTTP2_NV_FLAG_NONE});
        }

        return native;
      }

      template <std::size_t Size>
      static auto nativeFields(const ds::Array<std::pair<std::string_view, std::string_view>, Size>& fields) -> ds::Array<nghttp2_nv, Size> {
        ds::Array<nghttp2_nv, Size> native;

        for (std::size_t index = 0; index < Size; ++index) {
          const auto& [name, value] = fields[index];

          native.atMut(index) = {reinterpret_cast<std::uint8_t*>(const_cast<char*>(name.data())), reinterpret_cast<std::uint8_t*>(const_cast<char*>(value.data())), name.size(), value.size(), NGHTTP2_NV_FLAG_NONE};
        }

        return native;
      }

      static nghttp2_ssize read(nghttp2_session* session, std::int32_t id, std::uint8_t* output, std::size_t capacity, std::uint32_t* flags, nghttp2_data_source* source, void*) noexcept {
        auto& stream = *static_cast<Stream*>(source->ptr);
        const auto bytes = std::string_view{stream.outgoing}.substr(stream.sent, capacity);

        std::ranges::copy(bytes, output);
        stream.sent += bytes.size();
        if (stream.sent == stream.outgoing.size()) {
          *flags |= NGHTTP2_DATA_FLAG_EOF;
          if (!stream.trailers.empty()) {
            const auto native = nativeFields(stream.trailers);

            *flags |= NGHTTP2_DATA_FLAG_NO_END_STREAM;
            check(nghttp2_submit_trailer(session, id, native.data(), native.size()) == 0);
          }
        }

        return static_cast<nghttp2_ssize>(bytes.size());
      }

      static int header(nghttp2_session*, const nghttp2_frame* frame, const std::uint8_t* name, std::size_t name_size, const std::uint8_t* value, std::size_t value_size, std::uint8_t, void* context) noexcept {
        auto& peer = *static_cast<Peer*>(context);

        peer.streams[frame->hd.stream_id].headers.emplace_back(std::string{reinterpret_cast<const char*>(name), name_size}, std::string{reinterpret_cast<const char*>(value), value_size});
        return 0;
      }

      static int data(nghttp2_session*, std::uint8_t, std::int32_t id, const std::uint8_t* bytes, std::size_t size, void* context) noexcept {
        static_cast<Peer*>(context)->streams[id].body.append(reinterpret_cast<const char*>(bytes), size);
        return 0;
      }

      static int frame(nghttp2_session*, const nghttp2_frame* frame, void* context) noexcept {
        auto& peer = *static_cast<Peer*>(context);

        if (frame->hd.type == NGHTTP2_PING && (frame->hd.flags & NGHTTP2_FLAG_ACK)) {
          peer.pong = true;
        }

        if ((frame->hd.type == NGHTTP2_HEADERS || frame->hd.type == NGHTTP2_DATA) && (frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) {
          peer.streams[frame->hd.stream_id].complete = true;
        }

        return 0;
      }

      static int closed(nghttp2_session*, std::int32_t id, std::uint32_t code, void* context) noexcept {
        static_cast<Peer*>(context)->streams[id].reset = code;
        return 0;
      }

      nghttp2_session* session_ = nullptr;
      std::size_t received_ = 0;
    };

    struct Fixture {
      telar::testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      Owner owner;
      Peer client{false}, server{true};
      Http2EndpointConnection<ConcurrentMemory> connection;
      TestByteStream child, origin;

      explicit Fixture(bool fail_closed = true, std::string_view host = "fixture.test", std::uint32_t timeout_ms = 5000)
          : owner(memory, fail_closed, host, timeout_ms),
            connection(memory, IgnoreHttp2Capture{}, &owner, {.id = 17, .host = "fixture.test"}) {
        child.read_limit = origin.read_limit = 17;
        child.write_limit = origin.write_limit = 31;
        child.alternating_writes = origin.alternating_writes = true;
      }

      void step() {
        client.send(child);
        server.send(origin);
        connection.advance(child, origin, TunnelReadiness::available());
        client.receive(child);
        server.receive(origin);
        server.echo();
        owner.collect();
      }

      void automatic(std::uint32_t held = 0, bool edit = true) {
        for (auto cursor = owner.requests.begin(); cursor != owner.requests.end();) {
          if (HttpMessageCodec::decode(cursor->bytes).stream == held) {
            ++cursor;
            continue;
          }

          owner.answer(*cursor, edit);
          cursor = owner.requests.erase(cursor);
        }
      }

      template <typename Predicate>
      void until(Predicate&& done, std::source_location location = std::source_location::current()) {
        for (unsigned count = 0; count < 200000 && !done(); ++count) {
          step();
        }

        if (!done()) {
          std::fprintf(stderr, "H2: active=%u failed=%d owner=%zu client=%zu origin=%zu errors=%zu\n", connection.inflight(), connection.finished(), owner.requests.size(), client.streams.size(), server.streams.size(), owner.errors.size());
          for (const auto& error : owner.errors) {
            std::fprintf(stderr, "H2 error: %s\n", error.c_str());
          }
        }

        check(done(), location);
      }
    };

    void multiplexed() {
      Fixture fixture;
      const auto held = fixture.client.request("/held", std::string(65536, 'h'));
      const auto fast = fixture.client.request("/fast", std::string(128 * 1024, '\0'));

      fixture.client.ping();
      fixture.until([&] {
        fixture.automatic(held);
        return fixture.client.streams[fast].complete && fixture.client.pong;
      });

      check(!fixture.client.streams[held].complete && fixture.owner.requests.size() == 1);
      check(fixture.server.streams.size() == 1 && fixture.server.streams.begin()->second.field(":path") == "/edited/fast");
      check(fixture.client.streams[fast].field(":status") == "202");
      check(fixture.client.streams[fast].body == std::string{"response\0origin\0request\0", 24} + std::string(128 * 1024, '\0'));
      fixture.until([&] {
        fixture.automatic();
        return fixture.client.streams[held].complete;
      });

      check(fixture.server.streams.size() == 2 && fixture.owner.errors.empty() && !fixture.connection.finished());
    }

    void rejectedStream() {
      Fixture fixture;
      const auto rejected = fixture.client.request("/reject", "secret");

      fixture.until([&] {
        return !fixture.owner.requests.empty();
      });

      const auto ticket = fixture.owner.requests.front().ticket;

      fixture.owner.broker.decide(ticket, Verdict::reject, {});
      fixture.owner.requests.clear();
      fixture.until([&] {
        return fixture.client.streams[rejected].reset == NGHTTP2_CANCEL;
      });

      const auto next = fixture.client.request("/survives", "next");

      fixture.until([&] {
        fixture.automatic();
        return fixture.client.streams[next].complete;
      });

      check(!fixture.connection.finished() && fixture.server.streams.size() == 1);
    }

    void cancellation() {
      Fixture fixture;
      const auto canceled = fixture.client.request("/cancel", "secret");

      fixture.until([&] {
        return !fixture.owner.requests.empty();
      });

      const auto ticket = fixture.owner.requests.front().ticket;

      fixture.client.reset(canceled);
      fixture.until([&] {
        return !fixture.owner.broker.pending(ticket);
      });

      fixture.owner.broker.decide(ticket, Verdict::replace, {});
      check(fixture.server.streams.empty() && !fixture.connection.finished());
    }

    void streaming() {
      Fixture fixture{false, "unselected.test"};
      std::string body(2 * 1024 * 1024, 'x');
      const auto stream = fixture.client.request("/large", body);

      fixture.until([&] {
        return fixture.client.streams[stream].complete;
      });

      check(fixture.owner.requests.empty() && fixture.owner.errors.empty());
      check(fixture.client.streams[stream].body == std::string{"origin\0", 7} + body);
    }

    void originEof() {
      Fixture fixture;
      const auto stream = fixture.client.request("/last", "last");

      fixture.until([&] {
        for (auto cursor = fixture.owner.requests.begin(); cursor != fixture.owner.requests.end();) {
          if (HttpMessageCodec::decode(cursor->bytes).response) {
            return true;
          }

          fixture.owner.answer(*cursor);
          cursor = fixture.owner.requests.erase(cursor);
        }

        return false;
      });

      fixture.origin.ended = true;
      fixture.step();
      check(!fixture.connection.finished());
      fixture.until([&] {
        fixture.automatic();
        return fixture.client.streams[stream].complete;
      });

      check(fixture.client.streams[stream].field(":status") == "202");
    }

    void goaway() {
      Fixture fixture;
      const auto held = fixture.client.request("/held", "held");

      fixture.until([&] {
        return !fixture.owner.requests.empty();
      });

      fixture.server.goaway(0);
      fixture.until([&] {
        return fixture.client.streams[held].reset != 0;
      });

      check(!fixture.owner.broker.pending(fixture.owner.requests.front().ticket));
    }

    void timeout() {
      for (const bool closed : {false, true}) {
        Fixture fixture{closed, "fixture.test", 50};
        const auto stream = fixture.client.request("/timeout", "original");

        fixture.until([&] {
          return !fixture.owner.requests.empty();
        });

        const auto pending = fixture.owner.requests.front().ticket;

        check(fixture.connection.deadline().hasValue());
        std::this_thread::sleep_for(std::chrono::milliseconds{60});
        fixture.until([&] {
          fixture.automatic(0, false);
          return closed ? fixture.client.streams[stream].reset != 0 : fixture.client.streams[stream].complete;
        });

        check(!fixture.owner.broker.pending(pending));
        if (!closed) {
          check(fixture.client.streams[stream].body == std::string{"origin\0original", 15});
        }

        check(!fixture.connection.finished());
      }
    }

    void headMethods() {
      for (const bool original_head : {false, true}) {
        Fixture fixture;
        const auto stream = fixture.client.request(original_head ? "/be-get" : "/be-head", {}, original_head ? "HEAD" : "POST");

        fixture.until([&] {
          fixture.automatic();
          return fixture.client.streams[stream].complete || fixture.client.streams[stream].reset != 0;
        });

        check(fixture.client.streams[stream].complete && fixture.client.streams[stream].reset == 0);
        check(original_head ? fixture.client.streams[stream].body.empty() : fixture.client.streams[stream].body == std::string{"response\0", 9});
      }
    }

    using Fields = Peer::Fields;

    // The origin's stream for the request whose path ends with `suffix`, once the request is complete.
    auto originStream(Fixture& fixture, std::string_view suffix) -> ds::Option<std::int32_t> {
      for (const auto& [id, stream] : fixture.server.streams) {
        if (stream.complete && stream.field(":path").ends_with(suffix)) {
          return id;
        }
      }

      return ds::none;
    }

    bool settled(const Peer::Stream& stream) {
      return stream.complete || stream.reset != 0;
    }

    bool reported(const Owner& owner, std::string_view reason) {
      return !owner.errors.empty() && std::ranges::all_of(owner.errors, [&](const std::string& error) {
        return error == reason;
      });
    }

    // An intercepted stream whose body cannot be held whole, a declared length past the buffer, an
    // event stream or a tunnel, follows the policy: closed resets it before either peer sees it,
    // open forwards it unchanged; both report why.
    void unavailablePolicy() {
      for (const bool closed : {false, true}) {
        {
          Fixture fixture{closed};
          const std::string body(2 * HttpMessageLimits::body_bytes, 'b');
          const auto stream = fixture.client.request(Fields{{":method", "POST"}, {":scheme", "https"}, {":authority", "fixture.test"}, {":path", "/large"}, {"content-length", std::to_string(body.size())}}, body);

          fixture.until([&] {
            fixture.automatic(0, false);
            return settled(fixture.client.streams[stream]);
          });

          check(reported(fixture.owner, "http2_body_limit"));
          if (closed) {
            check(fixture.client.streams[stream].reset != 0 && fixture.server.streams.empty());
          } else {
            check(fixture.client.streams[stream].complete && fixture.client.streams[stream].body == std::string{"origin\0", 7} + body);
          }
        }

        {
          Fixture fixture{closed};

          fixture.server.echoing = false;
          const auto stream = fixture.client.request("/events", {}, "GET");

          fixture.until([&] {
            fixture.automatic(0, false);
            return originStream(fixture, "/events").hasValue();
          });

          fixture.server.respond(*originStream(fixture, "/events"), Fields{{":status", "200"}, {"content-type", "text/event-stream"}}, "data: x\n\n");
          fixture.until([&] {
            fixture.automatic(0, false);
            return settled(fixture.client.streams[stream]);
          });

          const auto& received = fixture.client.streams[stream];

          check(fixture.owner.errors == std::vector<std::string>{"http2_streaming_body"});
          if (closed) {
            check(received.reset != 0 && received.field(":status").empty() && received.body.empty());
          } else {
            check(received.complete && received.field("content-type") == "text/event-stream" && received.body == "data: x\n\n");
          }
        }

        {
          Fixture fixture{closed};

          fixture.server.echoing = false;
          const auto stream = fixture.client.request(Fields{{":method", "CONNECT"}, {":authority", "fixture.test:443"}}, "tunnel");

          fixture.until([&] {
            return closed ? fixture.client.streams[stream].reset != 0 : !fixture.server.streams.empty() && fixture.server.streams.begin()->second.complete;
          });

          check(fixture.owner.errors.front() == "http2_tunnel_body");
          if (closed) {
            check(fixture.server.streams.empty());
          } else {
            const auto& tunneled = fixture.server.streams.begin()->second;

            check(tunneled.field(":method") == "CONNECT" && tunneled.body == "tunnel");
          }
        }
      }
    }

    // nghttp2 accepts a comma in an authority, which names two hosts to a reader of the Host field,
    // and a status of 600; the endpoint refuses both, for that stream alone.
    void invalidMessages() {
      Fixture fixture;
      const auto listed = fixture.client.request(Fields{{":method", "GET"}, {":scheme", "https"}, {":authority", "fixture.test,other.test"}, {":path", "/listed"}}, {});

      fixture.until([&] {
        return fixture.client.streams[listed].reset != 0;
      });

      check(fixture.server.streams.empty() && fixture.owner.errors == std::vector<std::string>{"http2_message_failed"});
      fixture.server.echoing = false;
      const auto status = fixture.client.request("/status", {}, "GET");

      fixture.until([&] {
        fixture.automatic(0, false);
        return originStream(fixture, "/status").hasValue();
      });

      fixture.server.respond(*originStream(fixture, "/status"), Fields{{":status", "600"}}, "out of range");
      fixture.until([&] {
        return settled(fixture.client.streams[status]);
      });

      check(fixture.client.streams[status].reset != 0 && fixture.client.streams[status].field(":status").empty());
      check(fixture.owner.errors == std::vector<std::string>{"http2_message_failed", "http2_invalid_headers"});
      fixture.server.echoing = true;
      const auto next = fixture.client.request("/next", "next");

      fixture.until([&] {
        fixture.automatic();
        return fixture.client.streams[next].complete;
      });

      check(!fixture.connection.finished());
    }

    // A plugin's replacement that does not decode resets its own stream; the connection and its
    // other streams carry on.
    void invalidDecision() {
      Fixture fixture;
      const auto broken = fixture.client.request("/broken", "body");

      fixture.until([&] {
        return !fixture.owner.requests.empty();
      });

      const ds::Array<Byte, 3> garbage{1, 2, 3};

      fixture.owner.broker.decide(fixture.owner.requests.front().ticket, Verdict::replace, garbage);
      fixture.owner.requests.clear();
      fixture.until([&] {
        return settled(fixture.client.streams[broken]);
      });

      check(fixture.client.streams[broken].reset != 0 && fixture.server.streams.empty());
      check(fixture.owner.errors == std::vector<std::string>{"http2_invalid_decision"});
      const auto next = fixture.client.request("/next", "next");

      fixture.until([&] {
        fixture.automatic();
        return fixture.client.streams[next].complete;
      });

      check(!fixture.connection.finished() && fixture.server.streams.size() == 1);
    }

    // gRPC carries its status in response trailers: an intercepted response keeps them.
    void responseTrailers() {
      Fixture fixture;

      fixture.server.echoing = false;
      const auto stream = fixture.client.request("/grpc", "call");

      fixture.until([&] {
        fixture.automatic(0, false);
        return originStream(fixture, "/grpc").hasValue();
      });

      fixture.server.respond(*originStream(fixture, "/grpc"), Fields{{":status", "200"}, {"content-type", "application/grpc"}}, "reply", Fields{{"grpc-status", "0"}, {"grpc-message", "done"}});
      fixture.until([&] {
        fixture.automatic(0, false);
        return settled(fixture.client.streams[stream]);
      });

      const auto& received = fixture.client.streams[stream];

      check(received.complete && received.body == "reply" && fixture.owner.errors.empty());
      check(received.field("grpc-status") == "0" && received.field("grpc-message") == "done");
    }

    // The `:status` of every response block a stream received, in order.
    auto statuses(const Peer::Stream& stream) -> std::vector<std::string> {
      std::vector<std::string> result;

      for (const auto& [name, value] : stream.headers) {
        if (name == ":status") {
          result.push_back(value);
        }
      }

      return result;
    }

    // A child that opens with something other than the HTTP/2 preface fails the connection, before
    // any request reaches the origin.
    void badClientMagic() {
      Fixture fixture;

      fixture.child.input = "PRI * HTTP/2.0\r\n\r\nXX\r\n\r\n";
      fixture.until([&] {
        return fixture.connection.finished();
      });

      check(fixture.owner.errors == std::vector<std::string>{"http2_connection_failed"});
      check(fixture.server.streams.empty() && fixture.owner.requests.empty());
    }

    // Early hints reach the client ahead of the final response, which still follows; an origin that
    // keeps sending informational responses has the stream reset.
    void informationalResponses() {
      {
        Fixture fixture;

        fixture.server.echoing = false;
        const auto stream = fixture.client.request("/hints", {}, "GET");

        fixture.until([&] {
          fixture.automatic(0, false);
          return originStream(fixture, "/hints").hasValue();
        });

        const auto origin = *originStream(fixture, "/hints");

        fixture.server.inform(origin, Fields{{":status", "103"}, {"link", "</style.css>; rel=preload"}});
        fixture.server.respond(origin, Fields{{":status", "200"}}, "final");
        fixture.until([&] {
          fixture.automatic(0, false);
          return settled(fixture.client.streams[stream]);
        });

        const auto& received = fixture.client.streams[stream];

        check(received.complete && statuses(received) == std::vector<std::string>{"103", "200"});
        check(received.field("link") == "</style.css>; rel=preload" && received.body == "final" && fixture.owner.errors.empty());
      }

      {
        Fixture fixture;

        fixture.server.echoing = false;
        const auto stream = fixture.client.request("/chatty", {}, "GET");

        fixture.until([&] {
          fixture.automatic(0, false);
          return originStream(fixture, "/chatty").hasValue();
        });

        const auto origin = *originStream(fixture, "/chatty");

        for (unsigned count = 0; count < 9; ++count) {
          fixture.server.inform(origin, Fields{{":status", "103"}});
        }

        fixture.until([&] {
          return settled(fixture.client.streams[stream]);
        });

        check(fixture.client.streams[stream].reset != 0 && fixture.owner.errors == std::vector<std::string>{"http2_informational_limit"});
      }
    }

    // An intercepted request that expects 100-continue gets it before the hook decides, and the
    // origin receives the request without the expectation.
    void expectContinue() {
      Fixture fixture;
      const auto stream = fixture.client.request(Fields{{":method", "POST"}, {":scheme", "https"}, {":authority", "fixture.test"}, {":path", "/expect"}, {"expect", "100-continue"}}, "body");

      fixture.until([&] {
        return !fixture.owner.requests.empty() && fixture.client.streams[stream].field(":status") == "100";
      });

      fixture.until([&] {
        fixture.automatic(0, false);
        return fixture.client.streams[stream].complete;
      });

      const auto origin = originStream(fixture, "/expect");

      check(origin && fixture.server.streams[*origin].field("expect").empty());
      check(statuses(fixture.client.streams[stream]) == std::vector<std::string>{"100", "200"});
    }

    // The origin closing with a request still unanswered resets that stream, so the client does not
    // wait on it forever.
    void originEofInflight() {
      Fixture fixture;

      fixture.server.echoing = false;
      const auto stream = fixture.client.request("/pending", "body");

      fixture.until([&] {
        fixture.automatic(0, false);
        return originStream(fixture, "/pending").hasValue();
      });

      fixture.origin.ended = true;
      fixture.until([&] {
        return settled(fixture.client.streams[stream]);
      });

      check(fixture.client.streams[stream].reset != 0 && !fixture.client.streams[stream].complete);
    }
  }

  const telar::testing::Case case_unavailable_policy{"http2_endpoint.unavailable_policy", unavailablePolicy};
  const telar::testing::Case case_invalid_messages{"http2_endpoint.invalid_messages", invalidMessages};
  const telar::testing::Case case_invalid_decision{"http2_endpoint.invalid_decision", invalidDecision};
  const telar::testing::Case case_response_trailers{"http2_endpoint.response_trailers", responseTrailers};
  const telar::testing::Case case_bad_client_magic{"http2_endpoint.bad_client_magic", badClientMagic};
  const telar::testing::Case case_informational_responses{"http2_endpoint.informational_responses", informationalResponses};
  const telar::testing::Case case_expect_continue{"http2_endpoint.expect_continue", expectContinue};
  const telar::testing::Case case_origin_eof_inflight{"http2_endpoint.origin_eof_inflight", originEofInflight};
  const telar::testing::Case case_multiplexed{
      "http2_endpoint.multiplexed",
      [] {
        multiplexed();
      },
  };
  const telar::testing::Case case_rejected_stream{
      "http2_endpoint.rejected_stream",
      [] {
        rejectedStream();
      },
  };
  const telar::testing::Case case_cancellation{
      "http2_endpoint.cancellation",
      [] {
        cancellation();
      },
  };
  const telar::testing::Case case_streaming{
      "http2_endpoint.streaming",
      [] {
        streaming();
      },
  };
  const telar::testing::Case case_origin_eof{
      "http2_endpoint.origin_eof",
      [] {
        originEof();
      },
  };
  const telar::testing::Case case_goaway{
      "http2_endpoint.goaway",
      [] {
        goaway();
      },
  };
  const telar::testing::Case case_timeout{
      "http2_endpoint.timeout",
      [] {
        timeout();
      },
  };
  const telar::testing::Case case_head_methods{
      "http2_endpoint.head_methods",
      [] {
        headMethods();
      },
  };

}
