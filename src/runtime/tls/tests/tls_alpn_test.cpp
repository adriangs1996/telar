#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <openssl/ssl.h>
#include <sys/socket.h>

import std;
import telar.platform.primitives;
import telar.testing;
import telar.testing.socket_pair;
import telar.tls;
import telar.runtime.tls.interception;
import telar.runtime.tls.tests.hello_fixture;
import telar.platform.net;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::tls_test;

  std::vector<std::uint8_t> clientHello(std::span<const std::uint8_t> protocols) {
    TlsContext context{SSL_CTX_new(TLS_client_method())};

    check(context != nullptr);
    TlsConnection client{SSL_new(context.get())};

    check(client != nullptr);
    TlsBuffer input{BIO_new(BIO_s_mem())};
    TlsBuffer output{BIO_new(BIO_s_mem())};

    check(input != nullptr && output != nullptr);
    SSL_set_bio(client.get(), input.release(), output.release());
    SSL_set_connect_state(client.get());
    check(SSL_set_tlsext_host_name(client.get(), "origin.test") == 1);
    if (!protocols.empty()) {
      check(SSL_set_alpn_protos(client.get(), protocols.data(), static_cast<unsigned>(protocols.size())) == 0);
    }

    ERR_clear_error();
    const int result = SSL_do_handshake(client.get());

    check(result != 1 && SSL_get_error(client.get(), result) == SSL_ERROR_WANT_READ);

    char* bytes = nullptr;
    const auto length = BIO_get_mem_data(SSL_get_wbio(client.get()), &bytes);

    check(length > 5);
    return {reinterpret_cast<std::uint8_t*>(bytes), reinterpret_cast<std::uint8_t*>(bytes) + length};
  }

  void checkOffer(std::span<const std::uint8_t> names, std::span<const std::uint8_t> expected) {
    const auto hello = clientHello(names);
    AlpnOffer offer;

    offer.parse(std::span{hello}.subspan(5));
    check(offer.valid() && offer.serverName() == "origin.test");
    check(std::ranges::equal(offer.encoded(), expected));
    for (std::size_t prefix = 0; prefix < hello.size() - 5; ++prefix) {
      AlpnOffer truncated;

      truncated.parse(std::span{hello}.subspan(5, prefix));
      check(truncated.encoded().size() <= 12);
    }
  }

  void checkPeek(std::span<const std::uint8_t> names) {
    const auto hello = clientHello(names);

    for (const auto prefix : {std::size_t{0}, std::size_t{1}, std::size_t{4}, std::size_t{5}, hello.size() - 1, hello.size()}) {
      int sockets[2];

      check(::socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
      FileDescriptor child{sockets[0]};
      FileDescriptor proxy{sockets[1]};

      configureProxySocket(child.get());
      configureProxySocket(proxy.get());
      AlpnOffer offer;

      check(offer.peek(proxy.get()) == AlpnOffer::Read::pending);
      if (prefix != 0) {
        check(::send(child.get(), hello.data(), prefix, 0) == static_cast<ssize_t>(prefix));
      }

      check(offer.peek(proxy.get()) == (prefix == hello.size() ? AlpnOffer::Read::complete : AlpnOffer::Read::pending));
      if (prefix != hello.size()) {
        check(::send(child.get(), hello.data() + prefix, hello.size() - prefix, 0) == static_cast<ssize_t>(hello.size() - prefix));
      }

      check(offer.peek(proxy.get()) == AlpnOffer::Read::complete && std::ranges::equal(offer.encoded(), names));

      std::vector<std::uint8_t> retained(hello.size());

      check(::recv(proxy.get(), retained.data(), retained.size(), 0) == static_cast<ssize_t>(hello.size()) && retained == hello);
      check(::shutdown(child.get(), SHUT_WR) == 0);
      check(offer.peek(proxy.get()) == AlpnOffer::Read::ended);
    }
  }

  void checkFragments() {
    const auto record = clientHello({});
    const auto hello = std::span{record}.subspan(5);

    for (const auto split : {std::size_t{1}, std::size_t{3}, std::size_t{40}, hello.size() - 1}) {
      std::vector<std::uint8_t> records;
      auto append = [&](std::span<const std::uint8_t> part) {
        records.insert(records.end(), {22, 3, 1, static_cast<std::uint8_t>(part.size() >> 8), static_cast<std::uint8_t>(part.size())});
        records.insert(records.end(), part.begin(), part.end());
      };

      append(hello.first(split));
      append(hello.subspan(split));
      int sockets[2];

      check(::socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
      FileDescriptor writer{sockets[0]}, reader{sockets[1]};

      configureProxySocket(reader.get());
      check(::send(writer.get(), records.data(), records.size(), 0) == static_cast<ssize_t>(records.size()));
      AlpnOffer offer;

      check(offer.peek(reader.get()) == AlpnOffer::Read::complete && offer.valid() && offer.serverName() == "origin.test");
      std::vector<std::uint8_t> unchanged(records.size());

      check(::recv(reader.get(), unchanged.data(), unchanged.size(), 0) == static_cast<ssize_t>(unchanged.size()));
      check(unchanged == records);
    }
  }

  // Peeks a whole hello from a socket, as the transparent proxy reads it before deciding whether to
  // intercept.
  void peekHello(AlpnOffer& offer, std::span<const std::uint8_t> record) {
    int sockets[2];

    check(::socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    FileDescriptor child{sockets[0]};
    FileDescriptor proxy{sockets[1]};

    configureProxySocket(proxy.get());
    check(::send(child.get(), record.data(), record.size(), 0) == static_cast<ssize_t>(record.size()));
    check(offer.peek(proxy.get()) == AlpnOffer::Read::complete && offer.tls());
  }

  // The hello's server name decides whether a connection is intercepted and for which name a
  // certificate is minted, so a hello that names two hosts, or a host no resolver accepts, is invalid.
  void testMalformedHellos() {
    AlpnOffer offer;
    const std::array accepted{serverName("origin.test"), protocols()};

    peekHello(offer, helloRecord(accepted));
    check(offer.valid() && offer.serverName() == "origin.test");

    const std::array<std::string_view, 2> two_names{"origin.test", "other.test"};
    // A second server_name extension is refused even when it lists no host_name entry.
    const Extension unnamed{0, {0, 4, 1, 0, 1, 'x'}};
    const std::array<std::vector<Extension>, 5> malformed{{
        {serverName("origin.test"), serverName("other.test")},
        {serverName("origin.test"), unnamed},
        {{0, serverNames(two_names)}},
        {serverName("origin test")},
        {serverName("origin.test"), protocols(), protocols()},
    }};

    for (const auto& extensions : malformed) {
      AlpnOffer rejected;

      peekHello(rejected, helloRecord(extensions));
      check(!rejected.valid());
    }
  }

  // An ECH hello names a cover host in its outer server name: interception would act on the wrong
  // host, so the offer says the hello is encrypted.
  void testEncryptedClientHello() {
    const std::array plain{serverName("cover.test"), protocols()};
    const std::array encrypted{serverName("cover.test"), protocols(), encryptedHello()};
    AlpnOffer offer;

    peekHello(offer, helloRecord(plain));
    check(offer.valid() && !offer.encrypted());
    peekHello(offer, helloRecord(encrypted));
    check(offer.valid() && offer.encrypted() && offer.serverName() == "cover.test");
  }

  void testTlsAlpn() {
    constexpr std::array<std::uint8_t, 3> http2{2, 'h', '2'};
    constexpr std::array<std::uint8_t, 9> http11{8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
    constexpr std::array<std::uint8_t, 12> both{2, 'h', '2', 8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
    constexpr std::array<std::uint8_t, 12> reversed{8, 'h', 't', 't', 'p', '/', '1', '.', '1', 2, 'h', '2'};
    constexpr std::array<std::uint8_t, 4> unknown{3, 'f', 'o', 'o'};

    checkOffer(http2, http2);
    checkOffer(http11, http11);
    checkOffer(both, both);
    checkOffer(reversed, reversed);
    checkOffer(unknown, unknown);
    checkOffer({}, {});
    checkPeek(both);
  }

  // One TLS handshake record carrying `part` of a handshake message.
  std::vector<std::uint8_t> handshakeRecord(std::span<const std::uint8_t> part) {
    std::vector<std::uint8_t> record{22, 3, 1, static_cast<std::uint8_t>(part.size() >> 8), static_cast<std::uint8_t>(part.size())};

    record.insert(record.end(), part.begin(), part.end());
    return record;
  }

  // A connection that does not open with a ClientHello is settled at once, so a plain protocol does
  // not wait out the hello probe, and its bytes stay in the socket for the relay.
  void testPeekNonHello() {
    const std::string_view plain = "GET / HTTP/1.1\r\n\r\n";
    // A ServerHello that declares more bytes than its record carries.
    constexpr std::array<std::uint8_t, 4> server_hello{2, 0, 0, 100};
    const std::array inputs{
        std::vector<std::uint8_t>{plain.begin(), plain.end()},
        handshakeRecord(server_hello),
    };

    for (const auto& input : inputs) {
      SocketPair sockets;

      configureProxySocket(sockets.local.get());
      check(::send(sockets.remote.get(), input.data(), input.size(), 0) == static_cast<ssize_t>(input.size()));
      AlpnOffer offer;

      check(offer.peek(sockets.local.get()) == AlpnOffer::Read::complete);
      check(input.front() == 22 ? offer.tls() && !offer.valid() : !offer.tls());

      std::vector<std::uint8_t> retained(input.size());

      check(::recv(sockets.local.get(), retained.data(), retained.size(), 0) == static_cast<ssize_t>(input.size()) && retained == input);
    }
  }

  // A hello split over records that arrive apart waits for the rest instead of being judged on the
  // first record.
  void testRecordsArrivingLate() {
    const auto record = clientHello({});
    const auto hello = std::span{record}.subspan(5);
    const auto first = handshakeRecord(hello.first(40));
    const auto second = handshakeRecord(hello.subspan(40));
    SocketPair sockets;

    configureProxySocket(sockets.local.get());
    check(::send(sockets.remote.get(), first.data(), first.size(), 0) == static_cast<ssize_t>(first.size()));
    AlpnOffer offer;

    check(offer.peek(sockets.local.get()) == AlpnOffer::Read::pending);

    check(::send(sockets.remote.get(), second.data(), second.size(), 0) == static_cast<ssize_t>(second.size()));
    check(offer.peek(sockets.local.get()) == AlpnOffer::Read::complete && offer.valid() && offer.serverName() == "origin.test");
  }

  const telar::testing::Case case_tls_alpn{"tls_alpn.tls_alpn", testTlsAlpn};
  const telar::testing::Case case_check_fragments{"tls_alpn.check_fragments", checkFragments};
  const telar::testing::Case case_malformed_hellos{"tls_alpn.malformed_hellos", testMalformedHellos};
  const telar::testing::Case case_encrypted_client_hello{"tls_alpn.encrypted_client_hello", testEncryptedClientHello};
  const telar::testing::Case case_peek_non_hello{"tls_alpn.peek_non_hello", testPeekNonHello};
  const telar::testing::Case case_records_arriving_late{"tls_alpn.records_arriving_late", testRecordsArrivingLate};

}
