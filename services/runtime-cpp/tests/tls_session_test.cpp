#include "socket_pair.hpp"
#include "tls/session.hpp"
#include "tls_fixture.hpp"
#include <thread>

using namespace telar::runtime;

enum class SessionCase {
  http11,
  http2,
  no_alpn,
  tls12,
  untrusted_origin,
  wrong_hostname,
  expired_origin,
  untrusted_child
};

static void transferThrough(TlsSession<TlsTestMemory> &session, SSL *source, SSL *destination, TlsSide incoming) {
  constexpr std::string_view payload = "HTTP plaintext through authenticated TLS\r\n";
  ERR_clear_error();
  std::size_t written = 0;
  check(SSL_write_ex(source, payload.data(), payload.size(), &written) == 1 && written == payload.size());
  std::array<std::uint8_t, 1024> buffer;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
  StreamResult read{StreamResult::State::blocked};
  while (read.state == StreamResult::State::blocked) {
    check(std::chrono::steady_clock::now() < deadline);
    read = session.peek(incoming, buffer);
  }
  check(read.state == StreamResult::State::data && read.bytes == payload.size());
  const auto consumed = session.read(incoming, buffer);
  check(consumed.state == StreamResult::State::data && consumed.bytes == read.bytes);
  check(std::string_view{reinterpret_cast<const char *>(buffer.data()), read.bytes} == payload);
  const auto outgoing = incoming == TlsSide::child ? TlsSide::origin : TlsSide::child;
  StreamResult sent{StreamResult::State::blocked};
  while (sent.state == StreamResult::State::blocked) {
    check(std::chrono::steady_clock::now() < deadline);
    sent = session.write(outgoing, std::span{buffer}.first(read.bytes));
  }
  check(sent.state == StreamResult::State::data && sent.bytes == payload.size());
  std::size_t received = 0;
  for (;;) {
    check(std::chrono::steady_clock::now() < deadline);
    ERR_clear_error();
    const int result = SSL_read_ex(destination, buffer.data(), buffer.size(), &received);
    if (result == 1) {
      break;
    }
    const auto error = SSL_get_error(destination, result);
    check(error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE);
  }
  check(std::string_view{reinterpret_cast<const char *>(buffer.data()), received} == payload);
}

static void checkSession(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library, SessionCase scenario) {
  AuthorityDirectory directory;
  auto authority = CertificateAuthority<TlsTestMemory>::loadOrCreate(memory, library, directory.descriptor.get(), AuthorityKind::private_local);
  auto issuer = CertificatePair::authority("Origin fixture CA", CertificatePair::private_lifetime);
  auto leaf = issuer.mint("origin.test");
  if (scenario == SessionCase::expired_origin) {
    check(X509_gmtime_adj(X509_getm_notAfter(leaf.certificate.get()), -1) != nullptr);
    check(X509_sign(leaf.certificate.get(), issuer.key.get(), EVP_sha256()) > 0);
  }
  TlsTrustStore trust{memory, library};
  if (scenario != SessionCase::untrusted_origin) {
    trust.add(issuer.certificate.get());
  }
  TlsContexts contexts{memory, library, trust};
  TlsContext server_context{SSL_CTX_new(TLS_server_method())};
  TlsContext client_context{SSL_CTX_new(TLS_client_method())};
  check(server_context != nullptr && client_context != nullptr);
  check(SSL_CTX_use_certificate(server_context.get(), leaf.certificate.get()) == 1);
  check(SSL_CTX_use_PrivateKey(server_context.get(), leaf.key.get()) == 1);
  check(SSL_CTX_add1_chain_cert(server_context.get(), issuer.certificate.get()) == 1);
  check(SSL_CTX_set_num_tickets(server_context.get(), 0) == 1);
  if (scenario != SessionCase::untrusted_child) {
    check(X509_STORE_add_cert(SSL_CTX_get_cert_store(client_context.get()), authority.certificate()) == 1);
  }
  SSL_CTX_set_verify(client_context.get(), SSL_VERIFY_PEER, nullptr);
  if (scenario == SessionCase::tls12) {
    check(SSL_CTX_set_max_proto_version(client_context.get(), TLS1_2_VERSION) == 1);
    check(SSL_CTX_set_max_proto_version(server_context.get(), TLS1_2_VERSION) == 1);
  }

  constexpr std::array<unsigned char, 12> protocols{2, 'h', '2', 8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
  constexpr std::array<unsigned char, 2> http2{'h', '2'};
  constexpr std::array<unsigned char, 8> http11{'h', 't', 't', 'p', '/', '1', '.', '1'};
  AlpnSelection server_selection;
  check(server_selection.assign(scenario == SessionCase::http2 ? std::span<const unsigned char>{http2} : std::span<const unsigned char>{http11}));
  if (scenario != SessionCase::no_alpn) {
    SSL_CTX_set_alpn_select_cb(server_context.get(), &AlpnSelection::select, nullptr);
  }
  SocketPair downstream;
  SocketPair upstream;
  auto client = createTlsPeer(client_context.get(), downstream.remote.get(), false);
  auto server = createTlsPeer(server_context.get(), upstream.remote.get(), true);
  SSL_set_app_data(server.get(), &server_selection);
  check(SSL_set1_host(client.get(), "origin.test") == 1);
  if (scenario != SessionCase::no_alpn) {
    check(SSL_set_alpn_protos(client.get(), protocols.data(), protocols.size()) == 0);
  }

  TlsSession session{contexts, authority, TunnelSockets{downstream.local.get(), upstream.local.get()}, scenario == SessionCase::wrong_hostname ? "wrong.test" : "origin.test"};
  bool client_failed = false;
  bool server_failed = false;
  bool client_ready = false;
  bool server_ready = false;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  while (session.state() != decltype(session)::State::failed && (!client_ready || !server_ready || session.state() != decltype(session)::State::established)) {
    check(std::chrono::steady_clock::now() < deadline);
    if (!client_failed && !client_ready) {
      client_ready = advanceTlsPeer(client.get(), client_failed);
    }
    session.advance();
    if (!server_failed && !server_ready) {
      server_ready = advanceTlsPeer(server.get(), server_failed);
    }
    std::this_thread::yield();
  }

  using Failure = decltype(session)::Failure;
  switch (scenario) {
  case SessionCase::untrusted_origin:
  case SessionCase::wrong_hostname:
  case SessionCase::expired_origin:
    check(session.failure() == Failure::origin_handshake && !client_ready);
    return;
  case SessionCase::untrusted_child:
    check(session.failure() == Failure::child_handshake && client_failed);
    return;
  default:
    break;
  }
  check(client_ready && server_ready && session.failure() == Failure::none);
  check(session.protocol() == (scenario == SessionCase::http2 ? HttpProtocol::http2 : HttpProtocol::http11));
  const unsigned char *client_protocol = nullptr;
  const unsigned char *server_protocol = nullptr;
  unsigned client_length = 0;
  unsigned server_length = 0;
  SSL_get0_alpn_selected(client.get(), &client_protocol, &client_length);
  SSL_get0_alpn_selected(server.get(), &server_protocol, &server_length);
  check(std::ranges::equal(std::span{client_protocol, client_length}, std::span{server_protocol, server_length}));
  check(SSL_get_verify_result(client.get()) == X509_V_OK);
  transferThrough(session, client.get(), server.get(), TlsSide::child);
  transferThrough(session, server.get(), client.get(), TlsSide::origin);

  check(::shutdown(downstream.remote.get(), SHUT_WR) == 0);
  StreamResult closed{StreamResult::State::blocked};
  while (closed.state == StreamResult::State::blocked) {
    check(std::chrono::steady_clock::now() < deadline);
    std::array<std::uint8_t, 1> buffer;
    closed = session.read(TlsSide::child, buffer);
  }
  check(closed.state == StreamResult::State::ended || closed.state == StreamResult::State::failed);
  transferThrough(session, server.get(), client.get(), TlsSide::origin);
}

void testTlsSession(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library) {
  for (const auto scenario : {SessionCase::http11, SessionCase::http2, SessionCase::no_alpn, SessionCase::tls12, SessionCase::untrusted_origin, SessionCase::wrong_hostname, SessionCase::expired_origin, SessionCase::untrusted_child}) {
    checkSession(memory, library, scenario);
  }
}
