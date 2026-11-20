import std;
import telar.testing;
import telar.runtime.traffic.http1.head;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar::runtime;

  void testFieldNameWhitespace() {
    struct Head {
      std::string_view bytes;
      bool response;
    };

    // RFC 9112 5.1: a peer that rejects whitespace around a field name never reads these fields, so
    // framing the body by them would let a hidden message pass the relay.
    const telar::ds::Array whitespace{
        Head{"POST / HTTP/1.1\r\nTransfer-Encoding : chunked\r\n\r\n", false},
        Head{"POST / HTTP/1.1\r\nContent-Length\t: 5\r\n\r\n", false},
        Head{"POST / HTTP/1.1\r\nHost: a\r\n Transfer-Encoding: chunked\r\n\r\n", false},
        Head{"HTTP/1.1 200 OK\r\nContent-Length : 5\r\n\r\n", true},
    };

    for (const auto& head : whitespace) {
      check(!Http1Head::analyze(head.bytes, head.response), head.bytes);
    }

    const auto padded = Http1Head::analyze("POST / HTTP/1.1\r\nContent-Length: \t5 \r\n\r\n", false);

    check(padded && padded->framing.kind == Http1Framing::Kind::content_length && padded->framing.length == 5);
  }

  // A response with neither length nor chunking runs until the origin closes; reading it as empty
  // would hand its body to the relay as the next response.
  void testResponseUntilClose() {
    const auto response = Http1Head::analyze("HTTP/1.1 200 OK\r\n\r\n", true);

    check(response && response->framing.kind == Http1Framing::Kind::until_close && response->closes);

    const auto request = Http1Head::analyze("GET / HTTP/1.1\r\nHost: a\r\n\r\n", false);

    check(request && request->framing.kind == Http1Framing::Kind::none && !request->framing.hasBody());
  }

  // Keep-alive is the HTTP/1.1 default, and a Connection field without `close` keeps it; a field whose
  // name only matches a framing field in length frames nothing.
  void testConnectionTokensAndLookalikes() {
    const auto kept = Http1Head::analyze("GET / HTTP/1.1\r\nHost: a\r\nConnection: keep-alive\r\n\r\n", false);

    check(kept && !kept->closes);

    const auto closing = Http1Head::analyze("GET / HTTP/1.1\r\nHost: a\r\nConnection: keep-alive, close\r\n\r\n", false);

    check(closing && closing->closes);

    const auto length = Http1Head::analyze("POST / HTTP/1.1\r\nHost: a\r\nContent-Lengtx: 5\r\n\r\n", false);

    check(length && length->framing.kind == Http1Framing::Kind::none);

    const auto chunked = Http1Head::analyze("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encodinx: chunked\r\nContent-Length: 3\r\n\r\n", false);

    check(chunked && chunked->framing.kind == Http1Framing::Kind::content_length && chunked->framing.length == 3);
  }

  const telar::testing::Case case_field_name_whitespace{"http1_head.field_name_whitespace", testFieldNameWhitespace};
  const telar::testing::Case case_response_until_close{"http1_head.response_until_close", testResponseUntilClose};
  const telar::testing::Case case_connection_tokens{"http1_head.connection_tokens", testConnectionTokensAndLookalikes};

}
