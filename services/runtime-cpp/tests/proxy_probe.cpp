#include "protocol_peer.hpp"
#include "proxy/secret_file.hpp"
#include "text/base64.hpp"
#include <arpa/inet.h>
#include <atomic>
#include <filesystem>
#include <poll.h>
#include <source_location>
#include <thread>

using namespace telar;
using namespace telar::runtime;

static void require(bool condition, std::source_location location = std::source_location::current()) {
  if (!condition) {
    throw std::runtime_error{"Proxy oracle failed at line " + std::to_string(location.line()) + ": " + std::strerror(errno)};
  }
}

static void sendAll(int descriptor, std::span<const std::uint8_t> bytes) {
  while (!bytes.empty()) {
    const auto sent = ::send(descriptor, bytes.data(), bytes.size(), 0);
    if (sent < 0 && errno == EINTR) {
      continue;
    }
    require(sent > 0);
    bytes = bytes.subspan(static_cast<std::size_t>(sent));
  }
}

static void sendText(int descriptor, std::string_view text) {
  sendAll(descriptor, {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()});
}

class EchoOrigin {
public:
  EchoOrigin() : listener_(::socket(AF_INET, SOCK_STREAM, 0)) {
    require(static_cast<bool>(listener_));
    sockaddr_in address{};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    require(::bind(listener_.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) == 0);
    require(::listen(listener_.get(), 128) == 0);
    socklen_t length = sizeof(address);
    require(::getsockname(listener_.get(), reinterpret_cast<sockaddr *>(&address), &length) == 0);
    port_ = ntohs(address.sin_port);
    thread_ = std::jthread{[this](std::stop_token stop) { run(stop); }};
  }

  ~EchoOrigin() {
    thread_.request_stop();
    thread_.join();
    require(!failed_.load());
  }

  std::uint16_t port() const noexcept { return port_; }

private:
  void run(std::stop_token stop) noexcept {
    try {
      FileDescriptor client;
      std::array<std::uint8_t, 65536> buffer;
      while (!stop.stop_requested()) {
        pollfd ready{.fd = client ? client.get() : listener_.get(), .events = POLLIN, .revents = 0};
        if (::poll(&ready, 1, 20) <= 0) {
          continue;
        }
        if (!client) {
          client = FileDescriptor{::accept(listener_.get(), nullptr, nullptr)};
          require(static_cast<bool>(client));
          const int enabled = 1;
          require(::setsockopt(client.get(), SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) == 0);
          const timeval timeout{.tv_sec = 5, .tv_usec = 0};
          require(::setsockopt(client.get(), SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0);
          continue;
        }
        const auto read = ::recv(client.get(), buffer.data(), buffer.size(), 0);
        if (read <= 0) {
          client.reset();
        } else {
          sendAll(client.get(), std::span{buffer}.first(static_cast<std::size_t>(read)));
        }
      }
    } catch (...) {
      failed_.store(true);
    }
  }

  FileDescriptor listener_;
  std::uint16_t port_ = 0;
  std::atomic<bool> failed_ = false;
  std::jthread thread_;
};

static FileDescriptor connectProxy(std::uint16_t port) {
  FileDescriptor socket{::socket(AF_INET, SOCK_STREAM, 0)};
  require(static_cast<bool>(socket));
  const int enabled = 1;
  const timeval timeout{.tv_sec = 5, .tv_usec = 0};
  require(::setsockopt(socket.get(), SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) == 0);
  require(::setsockopt(socket.get(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
  require(::setsockopt(socket.get(), SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0);
  sockaddr_in address{};
  address.sin_len = sizeof(address);
  address.sin_family = AF_INET;
  address.sin_port = htons(port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  require(::connect(socket.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) == 0);
  return socket;
}

static std::string readHead(int descriptor) {
  std::string text;
  while (!text.ends_with("\r\n\r\n")) {
    char byte;
    const auto received = ::recv(descriptor, &byte, 1, 0);
    if (received < 0 && errno == EINTR) {
      continue;
    }
    require(received == 1 && text.size() < 4096);
    text.push_back(byte);
  }
  return text;
}

static std::string credential(const char *socket_path) {
  SystemAllocator memory;
  const auto path = std::filesystem::path{socket_path}.parent_path() / "proxy";
  FileDescriptor directory{::open(path.c_str(), O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)};
  require(static_cast<bool>(directory));
  const auto secret = ProxySecretFile::load(memory, directory.get());
  require(secret.has_value());
  std::array<char, ProxySecret::hexadecimal_bytes> hexadecimal;
  const auto user = "telar:" + std::string{*secret->formatHexadecimal(hexadecimal)};
  std::array<char, 128> encoded;
  const auto count = base64::encode({reinterpret_cast<const std::uint8_t *>(user.data()), user.size()}, encoded);
  require(count.has_value());
  return "Proxy-Authorization: Basic " + std::string{encoded.data(), *count} + "\r\n";
}

static FileDescriptor tunnel(std::uint16_t proxy_port, std::uint16_t origin_port, std::string_view authorization) {
  auto socket = connectProxy(proxy_port);
  sendText(socket.get(), "CONNECT 127.0.0.1:" + std::to_string(origin_port) + " HTTP/1.1\r\n" + std::string{authorization} + "\r\n");
  require(readHead(socket.get()) == "HTTP/1.1 200 Connection Established\r\n\r\n");
  return socket;
}

static void roundTrip(int descriptor, std::span<const std::uint8_t> payload) {
  sendAll(descriptor, payload);
  std::array<std::uint8_t, 65536> received;
  std::size_t length = 0;
  while (length < payload.size()) {
    const auto read = ::recv(descriptor, received.data() + length, payload.size() - length, 0);
    if (read < 0 && errno == EINTR) {
      continue;
    }
    require(read > 0);
    length += static_cast<std::size_t>(read);
  }
  require(std::equal(payload.begin(), payload.end(), received.begin()));
}

static void inspectEnvironment(ProtocolPeer &peer, std::ostream &dump, bool system_trusted) {
  constexpr std::string_view script = R"sh(
test "$HTTPS_PROXY" = "$https_proxy" || exit 11
case "$HTTPS_PROXY" in http://telar:*@127.0.0.1:*) ;; *) exit 12;; esac
test "$NODE_USE_ENV_PROXY" = 1 && test "$TELAR_PROXY_TLS" = 1 || exit 13
test -s "$NODE_EXTRA_CA_CERTS" && test -s "$SSL_CERT_FILE" || exit 14
test "${NODE_EXTRA_CA_CERTS##*/}" = "$1" || exit 16
for bundle in "$CURL_CA_BUNDLE" "$REQUESTS_CA_BUNDLE" "$AWS_CA_BUNDLE" "$GIT_SSL_CAINFO" "$CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE"; do
  test "$bundle" = "$SSL_CERT_FILE" || exit 15
done
printf 'proxy-environment-ok\n'
exec /bin/cat
)sh";
  const std::array<std::string_view, 5> arguments{"/bin/sh", "-c", script, "proxy-environment", system_trusted ? "ca-system-cert.pem" : "ca-cert.pem"};
  const auto pane = peer.exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = {80, 24, 0, 0}, .name = "Proxy", .launch = {.cwd = "/", .arguments = arguments}});
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  for (;;) {
    const auto text = peer.exchange<PaneText>(ReadPane{.request_id = 2, .pane_id = pane.pane_id, .rows = 24, .source = PaneTextSource::screen});
    if (text.text.contains("proxy-environment-ok")) {
      break;
    }
    require(std::chrono::steady_clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
  dump << "proxy-environment-ok\n";
  peer.send(ClosePane{.request_id = 3, .pane_id = pane.pane_id});
}

int main(int argc, char **argv) {
  if (argc != 5) {
    return 2;
  }
  try {
    ProtocolPeer peer{argv[1]};
    auto status = peer.exchange<ProxyStatus>(RequestRuntimeState{.client_identity = 1, .interactive = false});
    const std::string_view workload{argv[2]};
    const bool system_trusted = workload == "proxy-system-status";
    require(status.active && status.port && status.scope == ProxyScope::exact && status.system_trusted == system_trusted);
    const auto port = *status.port;
    std::ofstream dump{argv[4], std::ios::binary};
    const auto iterations = static_cast<unsigned>(std::stoul(argv[3]));
    const auto authorization = credential(argv[1]);
    EchoOrigin origin;
    std::array<std::uint8_t, 65536> bytes;
    for (std::size_t index = 0; index < bytes.size(); ++index) {
      bytes[index] = static_cast<std::uint8_t>(index * 29);
    }
    const auto payload = std::span{bytes}.first(workload == "proxy-throughput" ? bytes.size() : 64);
    FileDescriptor connection;
    if (workload == "proxy-latency" || workload == "proxy-throughput") {
      connection = tunnel(port, origin.port(), authorization);
      for (unsigned warmup = 0; warmup < 32; ++warmup) {
        roundTrip(connection.get(), payload);
      }
    }

    const auto started = std::chrono::steady_clock::now();
    if (workload == "proxy-status" || system_trusted) {
      inspectEnvironment(peer, dump, system_trusted);
      status.port = 45100;
      status.preferred_port.reset();
      peer.record(dump, status);
      auto rejected = connectProxy(port);
      sendText(rejected.get(), "CONNECT 127.0.0.1:443 HTTP/1.1\r\n\r\n");
      dump << readHead(rejected.get());
    } else if (workload == "proxy-connect" || workload == "proxy-latency" || workload == "proxy-throughput") {
      for (unsigned index = 0; index < iterations; ++index) {
        if (workload == "proxy-connect") {
          connection = tunnel(port, origin.port(), authorization);
        }
        roundTrip(connection.get(), payload);
        if (workload == "proxy-connect") {
          connection.reset();
        }
      }
    } else {
      return 2;
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    if (workload != "proxy-status" && !system_trusted) {
      dump.write(reinterpret_cast<const char *>(payload.data()), static_cast<std::streamsize>(payload.size()));
    }
    std::printf("{\"ns_per_iteration\":%.2f}\n", static_cast<double>(elapsed) / iterations);
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
