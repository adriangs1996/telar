#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <concepts>
#include <cstdint>
#include <span>
#include <cstddef>
#include <cstring>
#include <array>
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <exception>
#include <csignal>
#include <sys/socket.h>
#include "telar_platform/file_descriptor.hpp"
#include <netinet/in.h>
#include <netinet/tcp.h>
#include "telar_base/memory/fixed_text.hpp"
#include <string_view>
#include <arpa/inet.h>
#include <optional>
#include <openssl/ssl.h>
#include <memory>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include "telar_base/memory/allocator.hpp"
#include <openssl/crypto.h>
#include <stdexcept>
#include <ctime>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include "telar_platform/random_bytes.hpp"
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <unistd.h>
#endif
#include <unistd.h>
#include <cstdlib>
#include "telar_platform/trace.hpp"
#include <chrono>
#include <atomic>
#include <mutex>
#include "tls_fixture.hpp"
#include <thread>



#include "socket_pair.hpp"
import telar.runtime.tls.interception;

using namespace telar;
using namespace telar::runtime;

enum class SessionCase {
  http11,
  http2,
  no_alpn,
  other_alpn,
  tls12,
  tls13,
  untrusted_origin,
  wrong_hostname,
  expired_origin,
  untrusted_child,
  pinned_child,
  closed_before_hello
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
  const auto authority = std::make_shared<const CertificateAuthority<TlsTestMemory>>(CertificateAuthority<TlsTestMemory>::loadOrCreate(memory, library, directory.descriptor.get(), AuthorityKind::private_local));
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
    check(X509_STORE_add_cert(SSL_CTX_get_cert_store(client_context.get()), authority->certificate()) == 1);
  }
  SSL_CTX_set_verify(client_context.get(), SSL_VERIFY_PEER, nullptr);
  if (scenario == SessionCase::tls12 || scenario == SessionCase::tls13) {
    const auto version = scenario == SessionCase::tls12 ? TLS1_2_VERSION : TLS1_3_VERSION;
    for (auto *context : {client_context.get(), server_context.get()}) {
      check(SSL_CTX_set_min_proto_version(context, version) == 1);
      check(SSL_CTX_set_max_proto_version(context, version) == 1);
    }
  }

  constexpr std::array<unsigned char, 12> protocols{2, 'h', '2', 8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
  constexpr std::array<unsigned char, 2> http2{'h', '2'};
  constexpr std::array<unsigned char, 8> http11{'h', 't', 't', 'p', '/', '1', '.', '1'};
  constexpr std::array<unsigned char, 4> other_offer{3, 'f', 'o', 'o'};
  constexpr std::array<unsigned char, 3> other{'f', 'o', 'o'};
  AlpnSelection server_selection;
  check(server_selection.assign(scenario == SessionCase::http2 ? std::span<const unsigned char>{http2} : scenario == SessionCase::other_alpn ? std::span<const unsigned char>{other} : std::span<const unsigned char>{http11}));
  if (scenario != SessionCase::no_alpn) {
    SSL_CTX_set_alpn_select_cb(server_context.get(), &AlpnSelection::select, nullptr);
  }
  SocketPair downstream;
  SocketPair upstream;
  auto client = createTlsPeer(client_context.get(), downstream.remote.get(), false);
  auto server = createTlsPeer(server_context.get(), upstream.remote.get(), true);
  TlsPin pin{leaf.key.get()};
  if (scenario == SessionCase::pinned_child) {
    SSL_set_app_data(client.get(), &pin);
    SSL_set_verify(client.get(), SSL_VERIFY_PEER, &verifyTlsPin);
  }
  SSL_set_app_data(server.get(), &server_selection);
  check(SSL_set1_host(client.get(), "origin.test") == 1);
  if (scenario != SessionCase::no_alpn) {
    const auto offered = scenario == SessionCase::other_alpn ? std::span<const unsigned char>{other_offer} : std::span<const unsigned char>{protocols};
    check(SSL_set_alpn_protos(client.get(), offered.data(), offered.size()) == 0);
  }

  TlsSession session{contexts, authority, TunnelSockets{downstream.local.get(), upstream.local.get()}, scenario == SessionCase::wrong_hostname ? "wrong.test" : "origin.test"};
  bool client_failed = false;
  bool server_failed = false;
  bool client_ready = false;
  bool server_ready = false;
  if (scenario == SessionCase::closed_before_hello) {
    check(::shutdown(downstream.remote.get(), SHUT_WR) == 0);
    client_failed = true;
  }
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
  case SessionCase::closed_before_hello:
    check(session.failure() == Failure::client_hello && !client_ready && !server_ready);
    return;
  case SessionCase::untrusted_origin:
  case SessionCase::wrong_hostname:
  case SessionCase::expired_origin:
    check(session.failure() == Failure::origin_handshake && !client_ready);
    return;
  case SessionCase::untrusted_child:
    check(session.failure() == Failure::child_handshake && client_failed);
    return;
  case SessionCase::pinned_child:
    check(session.failure() == Failure::child_handshake && client_failed);
    check(pin.checked && !pin.matched && SSL_get_verify_result(client.get()) == X509_V_ERR_APPLICATION_VERIFICATION);
    return;
  default:
    break;
  }
  check(client_ready && server_ready && session.failure() == Failure::none);
  if (scenario == SessionCase::tls12 || scenario == SessionCase::tls13) {
    const auto version = scenario == SessionCase::tls12 ? TLS1_2_VERSION : TLS1_3_VERSION;
    check(SSL_version(client.get()) == version && SSL_version(server.get()) == version);
  }
  check(session.protocol() == (scenario == SessionCase::http2 ? HttpProtocol::http2 : (scenario == SessionCase::no_alpn || scenario == SessionCase::other_alpn) ? HttpProtocol::other : HttpProtocol::http11));
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

static void checkAuthorityRotation(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library) {
  AuthorityDirectory first_directory;
  AuthorityDirectory second_directory;
  auto first = std::allocate_shared<CertificateAuthority<TlsTestMemory>>(AllocatorRef<CertificateAuthority<TlsTestMemory>, TlsTestMemory>{memory}, CertificateAuthority<TlsTestMemory>::loadOrCreate(memory, library, first_directory.descriptor.get(), AuthorityKind::private_local));
  auto second = std::allocate_shared<CertificateAuthority<TlsTestMemory>>(AllocatorRef<CertificateAuthority<TlsTestMemory>, TlsTestMemory>{memory}, CertificateAuthority<TlsTestMemory>::loadOrCreate(memory, library, second_directory.descriptor.get(), AuthorityKind::private_local));
  check(X509_up_ref(first->certificate()) == 1);
  TlsCertificate first_root{first->certificate()};
  auto issuer = CertificatePair::authority("Rotation origin fixture", CertificatePair::private_lifetime);
  auto leaf = issuer.mint("origin.test");
  TlsTrustStore trust{memory, library};
  trust.add(issuer.certificate.get());
  TlsContexts contexts{memory, library, trust};
  TlsInterception<TlsTestMemory> interception{contexts, first};
  SocketPair old_downstream, old_upstream, new_downstream, new_upstream;
  auto old_session = interception.open(memory, {old_downstream.local.get(), old_upstream.local.get()}, "origin.test");
  std::weak_ptr<const CertificateAuthority<TlsTestMemory>> retained = first;
  first.reset();
  interception.replace(second);
  check(!retained.expired());
  auto new_session = interception.open(memory, {new_downstream.local.get(), new_upstream.local.get()}, "origin.test");
  interception.suspend(true);
  bool rejected = false;
  try { interception.open(memory, {new_downstream.local.get(), new_upstream.local.get()}, "origin.test"); }
  catch (const TlsError &) { rejected = true; }
  check(rejected);
  interception.suspend(false);

  auto handshake = [&](TlsSession<TlsTestMemory> &session, X509 *root, SocketPair &downstream, SocketPair &upstream) {
    TlsContext server_context{SSL_CTX_new(TLS_server_method())};
    TlsContext client_context{SSL_CTX_new(TLS_client_method())};
    check(SSL_CTX_use_certificate(server_context.get(), leaf.certificate.get()) == 1);
    check(SSL_CTX_use_PrivateKey(server_context.get(), leaf.key.get()) == 1);
    check(SSL_CTX_add1_chain_cert(server_context.get(), issuer.certificate.get()) == 1);
    check(X509_STORE_add_cert(SSL_CTX_get_cert_store(client_context.get()), root) == 1);
    SSL_CTX_set_verify(client_context.get(), SSL_VERIFY_PEER, nullptr);
    auto client = createTlsPeer(client_context.get(), downstream.remote.get(), false);
    auto server = createTlsPeer(server_context.get(), upstream.remote.get(), true);
    check(SSL_set1_host(client.get(), "origin.test") == 1);
    bool client_ready = false, server_ready = false, client_failed = false, server_failed = false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
    while (!client_ready || !server_ready || session.state() != TlsSession<TlsTestMemory>::State::established) {
      check(std::chrono::steady_clock::now() < deadline);
      if (!client_ready) { client_ready = advanceTlsPeer(client.get(), client_failed); }
      if (!server_ready) { server_ready = advanceTlsPeer(server.get(), server_failed); }
      session.advance();
      check(!client_failed && !server_failed && session.state() != TlsSession<TlsTestMemory>::State::failed);
    }
    check(SSL_get_verify_result(client.get()) == X509_V_OK);
    check(X509_check_issued(root, SSL_get0_peer_certificate(client.get())) == X509_V_OK);
    transferThrough(session, client.get(), server.get(), TlsSide::child);
    transferThrough(session, server.get(), client.get(), TlsSide::origin);
  };
  handshake(*old_session, first_root.get(), old_downstream, old_upstream);
  handshake(*new_session, second->certificate(), new_downstream, new_upstream);
  old_session.reset();
  check(retained.expired());
}

void testTlsSession(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library) {
  for (const auto scenario : {SessionCase::http11, SessionCase::http2, SessionCase::no_alpn, SessionCase::other_alpn, SessionCase::tls12, SessionCase::tls13, SessionCase::untrusted_origin, SessionCase::wrong_hostname, SessionCase::expired_origin, SessionCase::untrusted_child, SessionCase::pinned_child, SessionCase::closed_before_hello}) {
    checkSession(memory, library, scenario);
  }
  checkAuthorityRotation(memory, library);
}
