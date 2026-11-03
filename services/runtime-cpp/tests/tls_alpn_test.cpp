#include "check.hpp"
#include "telar_tls/handle.hpp"
#include "tls/alpn_offer.hpp"
#include <algorithm>
#include <vector>

using namespace telar::runtime;

static std::vector<std::uint8_t> clientHello(std::span<const std::uint8_t> protocols) {
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

  char *bytes = nullptr;
  const auto length = BIO_get_mem_data(SSL_get_wbio(client.get()), &bytes);
  check(length > 5);
  return {reinterpret_cast<std::uint8_t *>(bytes), reinterpret_cast<std::uint8_t *>(bytes) + length};
}

static void checkOffer(std::span<const std::uint8_t> names, std::span<const std::uint8_t> expected) {
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

static void checkPeek(std::span<const std::uint8_t> names) {
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

static void checkFragments() {
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
  checkFragments();
}
