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
import telar.tls;
import telar.runtime.tls.interception;
import telar.platform.net;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

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

  using Extension = std::pair<std::uint16_t, std::vector<std::uint8_t>>;

  void appendWord(std::vector<std::uint8_t>& output, std::size_t value) {
    output.push_back(static_cast<std::uint8_t>(value >> 8));
    output.push_back(static_cast<std::uint8_t>(value));
  }

  // A TLS 1.3 ClientHello record with one cipher suite and the extensions given.
  std::vector<std::uint8_t> helloRecord(std::span<const Extension> extensions) {
    std::vector<std::uint8_t> listed;

    for (const auto& [kind, body] : extensions) {
      appendWord(listed, kind);
      appendWord(listed, body.size());
      listed.insert(listed.end(), body.begin(), body.end());
    }

    std::vector<std::uint8_t> body{3, 3};

    body.resize(body.size() + 32, 0x5a);
    body.insert(body.end(), {0, 0, 2, 0x13, 0x01, 1, 0});
    appendWord(body, listed.size());
    body.insert(body.end(), listed.begin(), listed.end());
    std::vector<std::uint8_t> record{22, 3, 1};

    appendWord(record, body.size() + 4);
    record.insert(record.end(), {1, 0, static_cast<std::uint8_t>(body.size() >> 8), static_cast<std::uint8_t>(body.size())});
    record.insert(record.end(), body.begin(), body.end());
    return record;
  }

  std::vector<std::uint8_t> serverNames(std::span<const std::string_view> names) {
    std::vector<std::uint8_t> entries;

    for (const auto name : names) {
      entries.push_back(0);
      appendWord(entries, name.size());
      entries.insert(entries.end(), name.begin(), name.end());
    }

    std::vector<std::uint8_t> extension;

    appendWord(extension, entries.size());
    extension.insert(extension.end(), entries.begin(), entries.end());
    return extension;
  }

  Extension serverName(std::string_view name) {
    const std::array names{name};

    return {0, serverNames(names)};
  }

  Extension protocols() {
    return {16, {0, 3, 2, 'h', '2'}};
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
    const std::array encrypted{serverName("cover.test"), protocols(), Extension{0xfe0d, {0, 0, 1, 0, 1, 0x7f, 0, 0, 0, 0}}};
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

  const telar::testing::Case case_tls_alpn{"tls_alpn.tls_alpn", testTlsAlpn};
  const telar::testing::Case case_check_fragments{"tls_alpn.check_fragments", checkFragments};
  const telar::testing::Case case_malformed_hellos{"tls_alpn.malformed_hellos", testMalformedHellos};
  const telar::testing::Case case_encrypted_client_hello{"tls_alpn.encrypted_client_hello", testEncryptedClientHello};

}
