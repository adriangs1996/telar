#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdlib>
#include <cstring>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.testing;
import telar.testing.test_byte_stream;
import telar.runtime.traffic.http.message;
import telar.runtime.traffic.proxy.http2_capture_streams;
import telar.runtime.traffic.proxy.intercepted_relay;
import telar.runtime.traffic.proxy.runtime;
import telar.runtime.traffic.control_backend;
import telar.runtime.traffic.control_protocol;
import telar.runtime.traffic.tap.frames;
import telar.runtime.traffic.tap.protocol;
import telar.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::traffic;
  using telar::Byte;

  // Reads what `socket` has within 5 s; an empty result is the service closing it.
  std::vector<Byte> receiveSome(int socket, std::size_t limit) {
    pollfd descriptor{.fd = socket, .events = POLLIN, .revents = 0};

    check(::poll(&descriptor, 1, 5000) > 0);
    std::vector<Byte> bytes(limit);
    const auto count = ::recv(socket, bytes.data(), bytes.size(), 0);

    check(count >= 0);
    bytes.resize(static_cast<std::size_t>(count));
    return bytes;
  }

  void receiveAll(int socket, std::span<Byte> bytes) {
    while (!bytes.empty()) {
      const auto part = receiveSome(socket, bytes.size());

      check(!part.empty());
      std::ranges::copy(part, bytes.begin());
      bytes = bytes.subspan(part.size());
    }
  }

  traffic::Event receiveEvent(int socket, std::vector<Byte>& frame) {
    ds::Array<Byte, Protocol::prefix_bytes> prefix;

    receiveAll(socket, prefix.viewMut());
    plugins::FrameReader reader{prefix};

    frame.resize(reader.integer<std::uint32_t>());
    check(frame.size() <= Limits::http_frame_bytes);
    receiveAll(socket, frame);
    return Protocol::decode(frame);
  }

  void sendFrame(int socket, std::span<const Byte> body) {
    sendAll(socket, Protocol::prefix(body.size()));
    sendAll(socket, body);
  }

  // A plugin's HTTP interception peer on the service: it registers its rule and answers each
  // request the proxy hands it.
  struct Plugin {
    explicit Plugin(const std::string& path)
        : socket(connect(path)) {
      std::vector<Byte> output(Limits::frame_bytes);
      std::vector<Byte> frame;

      sendAll(socket.get(), Protocol::greeting(output, Role::intercept));
      check(receiveEvent(socket.get(), frame).kind == Kind::ready);
      sendFrame(socket.get(), InterceptionCodec::rule(output, {.host = "fixture.test", .directions = 1, .visibility = 3, .timeout_ms = 5000, .http = true}));
      check(receiveEvent(socket.get(), frame).kind == Kind::ready);
    }

    // The next HTTP request the service hands over: its ticket and the message, as HttpMessageCodec frames it.
    std::pair<std::uint64_t, std::vector<Byte>> request() {
      std::vector<Byte> frame;

      for (;;) {
        const auto event = receiveEvent(socket.get(), frame);
        if (event.kind == Kind::http_intercept_request) {
          const auto flow = FlowCodec::decode(event.bytes);

          return {flow.ticket, {flow.bytes.begin(), flow.bytes.end()}};
        }
      }
    }

    void replace(std::uint64_t ticket, std::span<const Byte> message) {
      std::vector<Byte> output(Limits::http_frame_bytes);

      sendFrame(socket.get(), InterceptionCodec::decision(output, ticket, Verdict::replace, message));
    }

    FileDescriptor socket;
  };

  using Connection = Http1Connection<IgnoreHttp1Capture>;

  // Advances the relay until `done`, while the service answers on its own thread.
  template <typename Predicate>
  void pump(Connection& connection, TestByteStream& child, TestByteStream& origin, Predicate&& done, std::source_location location = std::source_location::current()) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

    while (!done() && std::chrono::steady_clock::now() < deadline) {
      connection.advance(child, origin, TunnelReadiness::available());
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }

    check(done(), location);
  }

  // A plugin edits intercepted HTTP through the traffic service: its replacement reaches the origin,
  // and one that does not decode closes the plugin without changing what the origin receives.
  void testHttpInterceptionThroughService() {
    SystemAllocator system;
    BudgetAllocator budget{system, 64 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-http-service-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const auto path = std::string{directory.data()} + "/traffic.sock";
    const std::string request = "POST /original HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 6\r\n\r\nsecret";

    {
      Service service{memory, path, true};
      Plugin plugin{path};

      check(service.http() != nullptr);
      {
        ProxyCounters counters;
        Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{service.http(), FlowIdentity::of({.id = 41, .host = "fixture.test"})}};
        TestByteStream child, origin;

        child.input = request;
        origin.visible = 0;
        connection.advance(child, origin, TunnelReadiness::available());
        const auto [ticket, message] = plugin.request();
        auto view = HttpMessageCodec::decode(message);
        const ds::Array<Byte, 6> edited{'e', 'd', 'i', 't', 'e', 'd'};

        check(view.target == "/original" && std::ranges::equal(view.body, std::string_view{"secret"}));
        view.target = "/edited";
        view.body = edited;
        std::vector<Byte> output(HttpMessageLimits::message_bytes);

        plugin.replace(ticket, HttpMessageCodec::encode(output, view));
        pump(connection, child, origin, [&] {
          return origin.output.ends_with("\r\n\r\nedited");
        });

        check(origin.output.starts_with("POST /edited HTTP/1.1\r\n") && !origin.output.contains("secret"));
      }

      {
        ProxyCounters counters;
        Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{service.http(), FlowIdentity::of({.id = 42, .host = "fixture.test"})}};
        TestByteStream child, origin;

        child.input = request;
        origin.visible = 0;
        connection.advance(child, origin, TunnelReadiness::available());
        const auto [ticket, message] = plugin.request();
        const ds::Array<Byte, 3> garbage{1, 2, 3};

        plugin.replace(ticket, garbage);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

        while (!receiveSome(plugin.socket.get(), 65536).empty()) {
          check(std::chrono::steady_clock::now() < deadline);
        }

        pump(connection, child, origin, [&] {
          return origin.output == request;
        });
      }
    }

    check(budget.liveBytes() == 0);
    std::filesystem::remove_all(directory.data());
  }

  const telar::testing::Case case_http_interception_through_service{"traffic.http_interception_through_service", testHttpInterceptionThroughService};

}
