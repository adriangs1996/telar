import std;
import telar.websock.handshake;

namespace {

  using namespace std::string_view_literals;
  using telar::websock::HandshakeError;
  using telar::websock::parseHandshake;

  void require(bool condition, std::string_view name) {
    if (!condition) {
      throw std::runtime_error{std::format("Handshake regression: {}", name)};
    }
  }

  void requireError(std::string_view bytes, HandshakeError wanted, std::string_view name) {
    const auto result = parseHandshake(bytes);
    require(!result && result.error() == wanted, name);
  }

  // The sample handshake of RFC 6455 section 1.3.
  constexpr std::string_view rfc_request = "GET /chat HTTP/1.1\r\n"
                                           "Host: server.example.com\r\n"
                                           "Upgrade: websocket\r\n"
                                           "Connection: Upgrade\r\n"
                                           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                                           "Origin: http://example.com\r\n"
                                           "Sec-WebSocket-Protocol: chat, superchat\r\n"
                                           "Sec-WebSocket-Version: 13\r\n"
                                           "\r\n";

  // What to find in a request and what to put in its place.
  using Replacement = std::pair<std::string_view, std::string_view>;

  // The RFC request with its first `from` replaced; a missing `from` fails the test.
  std::string replaced(std::string_view text, Replacement replacement) {
    std::string result{text};
    const auto position = result.find(replacement.first);
    require(position != std::string::npos, replacement.first);
    result.replace(position, replacement.first.size(), replacement.second);
    return result;
  }

  void testAccepted() {
    const auto result = parseHandshake(rfc_request);
    require(result.has_value(), "rfc request parses");
    require(result->target == "/chat", "target");
    require(result->host == "server.example.com", "host");
    require(result->origin == "http://example.com", "origin");
    require(result->key == "dGhlIHNhbXBsZSBub25jZQ==", "key");
    require(result->protocols == "chat, superchat", "protocols");
    require(result->extensions.empty(), "no extensions");
    require(result->size == rfc_request.size(), "size covers the head");
  }

  void testLeavesFrames() {
    const std::string bytes = std::string{rfc_request} + "\x81\x05hello";
    const auto result = parseHandshake(bytes);
    require(result && result->size == rfc_request.size(), "bytes after the head are frames");
  }

  void testTolerated() {
    const auto mixed = replaced(replaced(rfc_request, {"Connection: Upgrade", "connection:keep-alive,  UPGRADE "}), {"Upgrade: websocket", "UPGRADE:\tWebSocket"});
    require(parseHandshake(mixed).has_value(), "case-insensitive names and tokens, OWS, lists");

    const auto repeated = replaced(rfc_request, {"Connection: Upgrade\r\n", "Connection: keep-alive\r\nConnection: Upgrade\r\n"});
    require(parseHandshake(repeated).has_value(), "repeated Connection");

    const auto later_minor = replaced(rfc_request, {"HTTP/1.1", "HTTP/1.2"});
    require(parseHandshake(later_minor).has_value(), "later HTTP/1 minor");

    const auto query = replaced(rfc_request, {"/chat", "/chat?room=1&x=%20"});
    require(parseHandshake(query).has_value() && parseHandshake(query)->target == "/chat?room=1&x=%20", "query target");

    const auto unknown = replaced(rfc_request, {"\r\n\r\n", "\r\nX-Note: caf\xc3\xa9\r\nContent-Length: 0\r\n\r\n"});
    require(parseHandshake(unknown).has_value(), "unknown fields with obs-text and an empty body");
  }

  void testIncomplete() {
    for (std::size_t size = 0; size < rfc_request.size(); ++size) {
      const auto result = parseHandshake(rfc_request.substr(0, size));
      if (result || result.error() != HandshakeError::incomplete) {
        require(false, "every prefix is incomplete");
        return;
      }
    }
  }

  void testLimits() {
    std::string large{"GET / HTTP/1.1\r\nX: "};
    large.resize(telar::websock::max_handshake_size, 'a');
    requireError(large, HandshakeError::too_large, "head without end at the limit");

    std::string under = large;
    under.pop_back();
    requireError(under, HandshakeError::incomplete, "head under the limit");

    std::string fits{rfc_request};
    constexpr auto filler_line = "X: \r\n"sv;
    fits.insert(fits.find("\r\n\r\n") + 2, "X: " + std::string(telar::websock::max_handshake_size - rfc_request.size() - filler_line.size(), 'a') + "\r\n");
    require(fits.size() == telar::websock::max_handshake_size && parseHandshake(fits).has_value(), "head of exactly the limit");
    requireError(replaced(fits, {"X: ", "X: a"}), HandshakeError::too_large, "head one byte over the limit");
  }

  void testRejected() {
    constexpr auto cases = std::to_array<Replacement>({
        {"GET /chat HTTP/1.1", "POST /chat HTTP/1.1"},
        {"GET /chat HTTP/1.1", "get /chat HTTP/1.1"},
        {"GET /chat HTTP/1.1", "GET /chat HTTP/1.0"},
        {"GET /chat HTTP/1.1", "GET /chat HTTP/2.0"},
        {"GET /chat HTTP/1.1", "GET  /chat HTTP/1.1"},
        {"GET /chat HTTP/1.1", "GET /c hat HTTP/1.1"},
        {"GET /chat HTTP/1.1", "GET http://server.example.com/chat HTTP/1.1"},
        {"GET /chat HTTP/1.1", "GET /chat HTTP/1.1 "},
        {"Host: server.example.com\r\n", ""},
        {"Host: server.example.com", "Host:"},
        {"Host: server.example.com\r\n", "Host: a\r\nHost: b\r\n"},
        {"Upgrade: websocket\r\n", ""},
        {"Upgrade: websocket", "Upgrade: h2c"},
        {"Connection: Upgrade\r\n", ""},
        {"Connection: Upgrade", "Connection: keep-alive"},
        {"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n", ""},
        {"dGhlIHNhbXBsZSBub25jZQ==", "dGhlIHNhbXBsZSBub25jZQ"},
        {"dGhlIHNhbXBsZSBub25jZQ==", "dGhlIHNhbXBsZSBub25jZQ=x"},
        {"dGhlIHNhbXBsZSBub25jZQ==", "dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="},
        {"Sec-WebSocket-Version: 13\r\n", ""},
        {"Sec-WebSocket-Version: 13", "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Version: 13"},
        {"Origin: http://example.com", "Origin: a\r\nOrigin: b"},
        {"chat, superchat", "chat\r\nSec-WebSocket-Protocol: superchat"},
        {"Host: server", "Host : server"},
        {"Host: server", "Host\t: server"},
        {"Host: server.example.com\r\n", "Host: server.example.com\r\n folded\r\n"},
        {"Host: server", "Ho\"st: server"},
        {"Host: server", ": server"},
        {"Host: server", "Host server"},
        {"Host: server", "Host: ser\x01ver"},
        {"Host: server", "Host: ser\x7fver"},
        {"Host: server", "Host: ser\rver"},
        {"Host: server.example.com\r\n", "Host: server.example.com\n"},
        {"\r\n\r\n", "\r\n\n"},
        {"\r\n\r\n", "\r\nContent-Length: 5\r\n\r\n"},
        {"\r\n\r\n", "\r\nTransfer-Encoding: chunked\r\n\r\n"},
    });
    for (const auto &replacement : cases) {
      requireError(replaced(rfc_request, replacement), HandshakeError::bad_request, std::format("rejects {:?} as {:?}", replacement.first, replacement.second));
    }

    requireError("GET / HTTP/1.1\n"sv, HandshakeError::bad_request, "bare LF ends the request line");
    requireError("\r\n"sv, HandshakeError::bad_request, "empty request line");
    requireError("GET / HTTP/1.1\0\r\n"sv, HandshakeError::bad_request, "NUL in the request line");
  }

  void testVersion() {
    requireError(replaced(rfc_request, {"Version: 13", "Version: 8"}), HandshakeError::unsupported_version, "older version");
    requireError(replaced(rfc_request, {"Version: 13", "Version: 8, 13"}), HandshakeError::unsupported_version, "version list");
  }

}

auto main() -> int {
  try {
    testAccepted();
    testLeavesFrames();
    testTolerated();
    testIncomplete();
    testLimits();
    testRejected();
    testVersion();
  } catch (const std::exception &error) {
    std::println(std::cerr, "{}", error.what());
    return 1;
  }
  return 0;
}
