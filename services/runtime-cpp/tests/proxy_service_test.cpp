#include "http2_fixture.hpp"
#include "proxy/service.hpp"
#include "text/base64.hpp"
#include "tls_fixture.hpp"
#include <thread>

using namespace telar::runtime;

enum class ProxyServiceScenario { opaque,
                                  http1,
                                  http2,
                                  http2_decode_failure };

class ServiceResolver {
public:
  static ResolutionSummary resolve(const char *hostname, std::span<NetworkAddress> addresses) noexcept {
    if (std::string_view{hostname} == "delayed.test") {
      resolving.store(true);
      while (!released.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds{1});
      }
    }
    sockaddr_in loopback{};
    loopback.sin_len = sizeof(loopback);
    loopback.sin_family = AF_INET;
    loopback.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addresses[0] = *NetworkAddress::copy(reinterpret_cast<const sockaddr *>(&loopback), sizeof(loopback));
    return {.found = 1};
  }

  inline static std::atomic<bool> resolving = false;
  inline static std::atomic<bool> released = false;
};

template <typename Predicate>
static void await(Predicate ready) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  while (!ready()) {
    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
}

static FileDescriptor connectLocal(std::uint16_t port) {
  FileDescriptor socket{::socket(AF_INET, SOCK_STREAM, 0)};
  check(static_cast<bool>(socket));
  sockaddr_in address{};
  address.sin_len = sizeof(address);
  address.sin_family = AF_INET;
  address.sin_port = htons(port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  check(::connect(socket.get(), reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0);
  configureProxySocket(socket.get());
  return socket;
}

static std::string request(const ProxySecret &secret, std::uint16_t port, std::string_view hostname) {
  std::array<char, ProxySecret::hexadecimal_bytes> hexadecimal;
  const auto user = "telar:" + std::string{*secret.formatHexadecimal(hexadecimal)};
  std::array<char, 128> encoded;
  const auto count = base64::encode({reinterpret_cast<const std::uint8_t *>(user.data()), user.size()}, encoded);
  check(count.has_value());
  return "CONNECT " + std::string{hostname} + ":" + std::to_string(port) + " HTTP/1.1\r\nProxy-Authorization: Basic " + std::string{encoded.data(), *count} + "\r\n\r\n";
}

static void writeText(int socket, std::string_view text) {
  check(::send(socket, text.data(), text.size(), 0) == static_cast<ssize_t>(text.size()));
}

static std::string readHead(int socket) {
  std::string head;
  await([&] {
    std::array<char, 4096> bytes;
    const auto read = ::recv(socket, bytes.data(), bytes.size(), 0);
    check(read > 0 || (read < 0 && socketWouldBlock(errno)));
    if (read > 0) {
      head.append(bytes.data(), static_cast<std::size_t>(read));
    }
    return head.ends_with("\r\n\r\n");
  });
  return head;
}

static void transferOpaque(int source, int destination) {
  std::string payload(256 * 1024, '\0');
  for (std::size_t index = 0; index < payload.size(); ++index) {
    payload[index] = static_cast<char>(index * 37);
  }
  std::size_t offset = 0;
  std::string received;
  await([&] {
    if (offset < payload.size()) {
      const auto written = ::send(source, payload.data() + offset, payload.size() - offset, 0);
      check(written > 0 || (written < 0 && socketWouldBlock(errno)));
      if (written > 0) {
        offset += static_cast<std::size_t>(written);
      }
    }
    std::array<char, 32768> buffer;
    const auto read = ::recv(destination, buffer.data(), buffer.size(), 0);
    check(read > 0 || (read < 0 && socketWouldBlock(errno)));
    if (read > 0) {
      received.append(buffer.data(), static_cast<std::size_t>(read));
    }
    return received.size() == payload.size();
  });
  check(received == payload);
}

static void transferTls(SSL *source, SSL *destination, std::string_view payload) {
  std::size_t offset = 0;
  std::string received;
  bool backpressure = false;
  await([&] {
    if (offset < payload.size()) {
      ERR_clear_error();
      std::size_t written = 0;
      const int result = SSL_write_ex(source, payload.data() + offset, payload.size() - offset, &written);
      if (result == 1) {
        offset += written;
      } else {
        const int error = SSL_get_error(source, result);
        check(error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE);
        backpressure = backpressure || error == SSL_ERROR_WANT_WRITE;
      }
    }
    std::array<char, 32768> buffer;
    ERR_clear_error();
    std::size_t read = 0;
    const int result = SSL_read_ex(destination, buffer.data(), buffer.size(), &read);
    if (result == 1) {
      received.append(buffer.data(), read);
    } else {
      const int error = SSL_get_error(destination, result);
      check(error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE);
    }
    return received.size() == payload.size();
  });
  check(backpressure && received == payload);
}

static std::string servicePayload(ProxyServiceScenario scenario, bool response) {
  std::string body(512 * 1024, '\0');
  for (std::size_t index = 0; index < body.size(); ++index) {
    body[index] = static_cast<char>(index * 19);
  }
  if (scenario == ProxyServiceScenario::http1) {
    return std::string{response ? "HTTP/1.1 200 OK\r\nContent-Length: 524288\r\n\r\n" : "POST /upload HTTP/1.1\r\nHost: origin.test\r\nContent-Length: 524288\r\n\r\n"} + body;
  }

  std::string payload{response ? std::string_view{} : Http2DirectionObserver<SystemAllocator>::client_preface};
  payload += http2Frame(Http2FrameKind::settings, 0, 0, {});
  if (scenario == ProxyServiceScenario::http2_decode_failure) {
    payload += http2Frame(Http2FrameKind::headers, 4, 1, "\xff");
  }
  payload += http2Frame(Http2FrameKind::headers, 4, 1, response ? "\x88" : "\x83\x84");
  payload += http2Frame(Http2FrameKind::headers, 4, 3, response ? "\x8d" : "\x83\x84");
  constexpr std::size_t fragment_size = 16 * 1024;
  for (std::size_t offset = 0; offset < body.size(); offset += fragment_size) {
    const auto stream = offset / fragment_size % 2 == 0 ? 1 : 3;
    const auto flags = offset + 2 * fragment_size >= body.size() ? 1 : 0;
    payload += http2Frame(Http2FrameKind::data, flags, stream, std::string_view{body}.substr(offset, fragment_size));
  }
  return payload;
}

template <EventLoop Poller>
static void checkService(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library, ProxyServiceScenario scenario, bool capture) {
  const bool intercepted = scenario != ProxyServiceScenario::opaque;
  const bool http2 = scenario == ProxyServiceScenario::http2 || scenario == ProxyServiceScenario::http2_decode_failure;
  AuthorityDirectory directory;
  const auto authority = CertificateAuthority<TlsTestMemory>::loadOrCreate(memory, library, directory.descriptor.get(), AuthorityKind::private_local);
  const auto issuer = CertificatePair::authority("Fixture origin CA", CertificatePair::private_lifetime);
  const auto leaf = issuer.mint("origin.test");
  TlsTrustStore trust{memory, library};
  trust.add(issuer.certificate.get());
  TlsContexts contexts{memory, library, trust};
  TlsInterception interception{contexts, authority};
  ProxyOptions options{memory};
  options.capture.enabled = capture;
  if (intercepted) {
    check(options.intercept_hosts.append("origin.test"));
    options.intercept_hosts.finish();
  }
  const auto secret = ProxySecret::generate();
  auto origin_listener = ProxyListener::bind(std::nullopt, {});
  ProxyService<TlsTestMemory, Poller, ServiceResolver> service{memory, options, secret, interception, ProxyListener::bind(std::nullopt, {})};
  auto child = connectLocal(service.port());
  writeText(child.get(), request(secret, origin_listener.port(), "origin.test"));
  check(readHead(child.get()) == "HTTP/1.1 200 Connection Established\r\n\r\n");
  FileDescriptor origin;
  await([&] { origin = origin_listener.accept(); return static_cast<bool>(origin); });

  if (!intercepted) {
    transferOpaque(child.get(), origin.get());
    check(::shutdown(child.get(), SHUT_WR) == 0);
    await([&] { char byte; return ::recv(origin.get(), &byte, 1, 0) == 0; });
    transferOpaque(origin.get(), child.get());
    check(::shutdown(origin.get(), SHUT_WR) == 0);
    await([&] { char byte; return ::recv(child.get(), &byte, 1, 0) == 0; });
    await([&] { return service.active() == 0; });
    check(service.counters().read(ProxyCounter::passthrough_connection) == 1);
    check(service.captures().metrics().started == 0 && service.captures().metrics().queued == 0);
    return;
  }

  TlsContext server_context{SSL_CTX_new(TLS_server_method())};
  TlsContext client_context{SSL_CTX_new(TLS_client_method())};
  check(server_context != nullptr && client_context != nullptr);
  check(SSL_CTX_use_certificate(server_context.get(), leaf.certificate.get()) == 1);
  check(SSL_CTX_use_PrivateKey(server_context.get(), leaf.key.get()) == 1);
  check(X509_STORE_add_cert(SSL_CTX_get_cert_store(client_context.get()), authority.certificate()) == 1);
  SSL_CTX_set_verify(client_context.get(), SSL_VERIFY_PEER, nullptr);
  check(SSL_CTX_set_num_tickets(server_context.get(), 0) == 1);
  AlpnSelection server_selection;
  if (http2) {
    constexpr std::array<unsigned char, 2> name{'h', '2'};
    check(server_selection.assign(name));
    SSL_CTX_set_alpn_select_cb(server_context.get(), &AlpnSelection::select, nullptr);
  }
  auto client = createTlsPeer(client_context.get(), child.get(), false);
  auto server = createTlsPeer(server_context.get(), origin.get(), true);
  if (http2) {
    constexpr std::array<unsigned char, 3> offer{2, 'h', '2'};
    check(SSL_set_alpn_protos(client.get(), offer.data(), offer.size()) == 0);
    SSL_set_app_data(server.get(), &server_selection);
  }
  check(SSL_set1_host(client.get(), "origin.test") == 1);
  bool client_ready = false;
  bool server_ready = false;
  await([&] {
    bool failed = false;
    if (!client_ready) {
      client_ready = advanceTlsPeer(client.get(), failed);
      check(!failed);
    }
    if (!server_ready) {
      server_ready = advanceTlsPeer(server.get(), failed);
      check(!failed);
    }
    return client_ready && server_ready;
  });
  const int small_buffer = 1024;
  check(::setsockopt(child.get(), SOL_SOCKET, SO_SNDBUF, &small_buffer, sizeof(small_buffer)) == 0);
  check(::setsockopt(origin.get(), SOL_SOCKET, SO_SNDBUF, &small_buffer, sizeof(small_buffer)) == 0);
  transferTls(client.get(), server.get(), servicePayload(scenario, false));
  transferTls(server.get(), client.get(), servicePayload(scenario, true));
  check(!service.failed() && service.counters().read(ProxyCounter::passthrough_connection) == 0);
  if (http2) {
    server.reset();
    origin.reset();
    await([&] { return service.active() == 0; });
    check(service.counters().read(ProxyCounter::h2_decode_failure) == (scenario == ProxyServiceScenario::http2_decode_failure ? 2 : 0));
  }

  const std::size_t expected = !capture || scenario == ProxyServiceScenario::http2_decode_failure ? 0 : http2 ? 4
                                                                                                              : 2;
  await([&] { return service.captures().metrics().queued == expected; });
  for (std::size_t index = 0; index < expected; ++index) {
    auto half = service.captures().tryReceive();
    check(half && (*half)->host() == "origin.test" && (*half)->key.connection == 1);
    check((*half)->started_at_ms > 0 && (*half)->finished_at_ms >= (*half)->started_at_ms);
    check((*half)->protocol == (http2 ? CaptureProtocol::http2 : CaptureProtocol::http1));
    check((*half)->body.size() == (http2 ? 256 : 512) * 1024);
    for (std::size_t offset = 0; offset < (*half)->body.size(); ++offset) {
      check((*half)->body.bytes()[offset] == static_cast<std::uint8_t>(offset * 19));
    }
    check(!(*half)->head.truncated && !(*half)->body.truncated && !(*half)->body_decoded);
    if ((*half)->side == CaptureSide::request) {
      check((*half)->method() == "POST" && (*half)->target() == (http2 ? "/" : "/upload"));
      check((*half)->outcome == CaptureOutcome::finished);
    } else {
      const bool failed = http2 && (*half)->key.stream == 3;
      check((*half)->status_code == (failed ? 404 : 200));
      check((*half)->outcome == (failed ? CaptureOutcome::failed : CaptureOutcome::finished));
    }
  }
  if (!http2) {
    server.reset();
    client.reset();
    origin.reset();
    child.reset();
    await([&] { return service.active() == 0; });
  }
  check(service.captures().reservedBytes() == 0);
}

static void checkAdmissionAndStop(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library) {
  AuthorityDirectory directory;
  const auto authority = CertificateAuthority<TlsTestMemory>::loadOrCreate(memory, library, directory.descriptor.get(), AuthorityKind::private_local);
  TlsTrustStore trust{memory, library};
  TlsContexts contexts{memory, library, trust};
  TlsInterception interception{contexts, authority};
  ProxyOptions options{memory};
  const auto secret = ProxySecret::generate();
  std::optional<ProxyService<TlsTestMemory, Kqueue, ServiceResolver>> service;
  service.emplace(memory, options, secret, interception, ProxyListener::bind(std::nullopt, {}));
  std::array<FileDescriptor, ProxyConnectionPolicy::maximum_unauthenticated> silent;
  for (auto &socket : silent) {
    socket = connectLocal(service->port());
  }
  await([&] { return service->active() == silent.size(); });
  auto refused = connectLocal(service->port());
  writeText(refused.get(), "CONNECT origin.test:443 HTTP/1.1\r\n");
  check(readHead(refused.get()) == "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
  check(service->counters().read(ProxyCounter::unauthenticated_refusal) == 1);
  for (auto &socket : silent) {
    socket.reset();
  }
  await([&] { return service->active() == 0; });

  auto delayed = connectLocal(service->port());
  writeText(delayed.get(), request(secret, 443, "delayed.test"));
  await([] { return ServiceResolver::resolving.load(); });
  const auto started = std::chrono::steady_clock::now();
  service.reset();
  check(std::chrono::steady_clock::now() - started < std::chrono::seconds{2});
  ServiceResolver::released.store(true);
  await([] { return NameResolutions<ServiceResolver>::pending() == 0; });
}

void testProxyService(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library) {
  for (const auto scenario : {ProxyServiceScenario::opaque, ProxyServiceScenario::http1, ProxyServiceScenario::http2, ProxyServiceScenario::http2_decode_failure}) {
    for (const bool capture : {false, true}) {
      checkService<Kqueue>(memory, library, scenario, capture);
    }
  }
  checkAdmissionAndStop(memory, library);
}
