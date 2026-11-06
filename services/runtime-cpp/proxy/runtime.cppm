module;

#include "telar_platform/random_bytes.hpp"
#include <cstddef>
#include <cstring>
#include <string_view>
#include <algorithm>
#include <array>
#include <charconv>
#include <cstdint>
#include <cstdlib>
#include <optional>
#include <span>
#include "telar_base/memory/allocator.hpp"
#include "telar_base/program_identity.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cerrno>
#include <exception>
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <sys/types.h>
#include <limits.h>


#include <bitset>


#include <csignal>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>


#include <fcntl.h>
#include <sys/stat.h>
#include <openssl/sha.h>
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
#include <dirent.h>


#include <chrono>
#include <concepts>


#include <pthread.h>
#include <arpa/inet.h>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/base64.hpp"
#include <variant>
#include <atomic>
#include <netdb.h>
#include "telar_platform/trace.hpp"
#include <type_traits>
#include <utility>
#include <limits>
#include <brotli/decode.h>
#include <brotli/encode.h>
#include <zlib.h>
#include <memory>
#include <stdexcept>
#include <zstd.h>
#include "telar_client/codecs/telar_wire.hpp"
#include <bit>
#include <initializer_list>
#include <cassert>
#include <condition_variable>
#include <mutex>
#include <nghttp2/nghttp2.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <openssl/crypto.h>
#include <ctime>
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__))
#endif
#include <thread>


#if (defined(__APPLE__))
#include <CoreFoundation/CoreFoundation.h>
#endif
#if (defined(__APPLE__))
#include <Security/Security.h>
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <openssl/x509.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#include <sys/un.h>
#include <sys/uio.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#include <spawn.h>
#include <sys/wait.h>
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <sys/resource.h>

export module telar.runtime.proxy.runtime;

export import telar.runtime.proxy.authenticate;
export import telar.base.memory;
export import telar.platform;


export import telar.runtime.proxy.relay_direction;


export import telar.runtime.proxy.http2_capture_streams;
export import telar.runtime.proxy.http1_capture;


export import telar.runtime.proxy.connection;


export import telar.runtime.exchange_capture.pipeline;
export import telar.runtime.platform.system_certificates;
export import telar.runtime.redirect.ingress;
export import telar.runtime.tls.system_root_bundle;


export import telar.tls;

// Interface: proxy/client_configuration.cppm
export {
namespace telar::runtime {

class ProxyClientConfiguration {
public:
  ProxyClientConfiguration() noexcept = default;

  inline explicit ProxyClientConfiguration(ProxyStatus status, const ProxySecret &secret, std::string_view certificate, std::string_view bundle) noexcept
      : status_(status), secret_(&secret), certificate_(certificate), bundle_(bundle) {}

  inline const ProxyStatus &status() const noexcept {
    return status_;
  }

  template <Allocator Memory>
  inline void apply(Command<Memory> &command) const {
    if (!status_.active) {
      return;
    }

    SensitiveBuffer<256> storage;
    const auto bytes = storage.bytes();
    const auto url = secret_->formatUrl({reinterpret_cast<char *>(bytes.data()), bytes.size()}, *status_.port);
    if (!url) {
      throw SystemError{"Format child proxy URL", EOVERFLOW};
    }
    command.setEnvironment("HTTPS_PROXY", *url);
    command.setEnvironment("https_proxy", *url);
    command.setEnvironment("NODE_USE_ENV_PROXY", "1");
    command.setEnvironment("NODE_EXTRA_CA_CERTS", certificate_);
    for (const auto name : {"SSL_CERT_FILE", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "AWS_CA_BUNDLE", "GIT_SSL_CAINFO", "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE"}) {
      command.setEnvironment(name, bundle_);
    }
    command.setEnvironment("TELAR_PROXY_TLS", "1");
  }

private:
  ProxyStatus status_{};
  const ProxySecret *secret_ = nullptr;
  std::string_view certificate_;
  std::string_view bundle_;
};

}
}

// Interface: proxy/port_range.cppm
export {
namespace telar::runtime {

struct ProxyPortRange {
  static constexpr std::uint16_t first = 45100;
  static constexpr std::uint16_t count = 128;
  using Set = std::bitset<count>;

  static constexpr bool contains(std::uint16_t port) noexcept {
    return port >= first && port < first + count;
  }
};

}
}

// Interface: proxy/listener.cppm
export {
namespace telar::runtime {

class ProxyListener {
public:
  inline static ProxyListener bind(std::optional<std::uint16_t> preferred, const ProxyPortRange::Set &reserved) {
    if (preferred) {
      if (auto listener = tryPort(*preferred, true)) {
        return std::move(*listener);
      }
    }

    for (const bool use_reserved : {false, true}) {
      for (std::uint16_t offset = 0; offset < ProxyPortRange::count; ++offset) {
        if (reserved.test(offset) != use_reserved) {
          continue;
        }
        if (auto listener = tryPort(ProxyPortRange::first + offset, false)) {
          return std::move(*listener);
        }
      }
    }
    throw SystemError{"No proxy port available", EADDRINUSE};
  }

  inline FileDescriptor accept() const {
    FileDescriptor child{::accept(socket_.get(), nullptr, nullptr)};
    if (!child) {
      if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return child;
      }
      throw SystemError{"Accept proxy connection"};
    }

    configureProxySocket(child.get());
    return child;
  }

  inline int descriptor() const noexcept {
    return socket_.get();
  }

  inline std::uint16_t port() const noexcept {
    return port_;
  }

  inline void close() noexcept {
    socket_.reset();
  }

private:
  inline explicit ProxyListener(FileDescriptor socket, std::uint16_t port) noexcept
      : socket_(std::move(socket)),
        port_(port) {}

  inline static FileDescriptor openSocket() {
    FileDescriptor socket{::socket(AF_INET, SOCK_STREAM, 0)};
    if (!socket) {
      throw SystemError{"Create proxy socket"};
    }
    configureProxySocket(socket.get());
    return socket;
  }

  inline static sockaddr_in address(std::uint16_t port) noexcept {
    sockaddr_in address{};
#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return address;
  }

  inline static std::optional<ProxyListener> tryPort(std::uint16_t port, bool reclaim) {
    auto socket = listen(port, false);
    if (!socket && reclaim && !answers(port)) {
      // BSD reuse can shadow a wildcard listener; reclaim only a refused port.
      socket = listen(port, true);
    }
    if (!socket) {
      return std::nullopt;
    }
    return ProxyListener{std::move(socket), port};
  }

  inline static FileDescriptor listen(std::uint16_t port, bool reuse_closed) {
    auto socket = openSocket();
    if (reuse_closed) {
      const int enabled = 1;
      if (::setsockopt(socket.get(), SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0) {
        throw SystemError{"Reclaim proxy port"};
      }
    }

    const auto loopback = address(port);
    if (::bind(socket.get(), reinterpret_cast<const sockaddr *>(&loopback), sizeof(loopback)) != 0 || ::listen(socket.get(), backlog) != 0) {
      if (errno == EADDRINUSE) {
        return FileDescriptor{};
      }
      throw SystemError{"Bind proxy listener"};
    }
    return socket;
  }

  inline static bool answers(std::uint16_t port) noexcept {
    try {
      auto socket = openSocket();
      const auto loopback = address(port);
      if (::connect(socket.get(), reinterpret_cast<const sockaddr *>(&loopback), sizeof(loopback)) == 0) {
        return true;
      }
      if (errno == ECONNREFUSED) {
        return false;
      }
      if (errno != EINPROGRESS) {
        return true;
      }

      pollfd pending{.fd = socket.get(), .events = POLLOUT, .revents = 0};
      if (::poll(&pending, 1, probe_timeout_ms) != 1) {
        return true;
      }
      int failure = 0;
      socklen_t length = sizeof(failure);
      return ::getsockopt(socket.get(), SOL_SOCKET, SO_ERROR, &failure, &length) != 0 || failure != ECONNREFUSED;
    } catch (...) {
      return true;
    }
  }

  static constexpr int backlog = 128;
  static constexpr int probe_timeout_ms = 50;
  FileDescriptor socket_;
  std::uint16_t port_;
};

}
}

// Interface: proxy/port_memory.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class ProxyPortMemory {
public:
  inline explicit ProxyPortMemory(Memory &memory, int directory, std::string_view endpoint, bool inherit_legacy)
      : memory_(memory),
        directory_(directory),
        endpoint_(endpoint, AllocatorRef<char, Memory>{memory}) {
    if (endpoint.size() > PATH_MAX || endpoint.contains('\0')) {
      throw SystemError{"Invalid proxy endpoint path", EINVAL};
    }

    identify(endpoint);
    Vector<unsigned char, Memory> bytes{AllocatorRef<unsigned char, Memory>{memory_}};
    if (const auto record = recall(name_.data(), bytes)) {
      own_ = record->port;
    }
    if (inherit_legacy) {
      if (const auto record = recall(legacy_name, bytes)) {
        legacy_ = record->port;
      }
    }

    scan([&](const char *name, const Record &record) {
      if (vanished(record.endpoint)) {
        ::unlinkat(directory_, name, 0);
      } else {
        reserved_.set(record.port - ProxyPortRange::first);
      }
    });
    if (own_ && legacy_) {
      reserved_.set(*legacy_ - ProxyPortRange::first);
    }
  }

  inline std::optional<std::uint16_t> preferred() const noexcept {
    return own_ ? own_ : legacy_;
  }

  inline const ProxyPortRange::Set &reserved() const noexcept {
    return reserved_;
  }

  inline std::string_view filename() const noexcept {
    return {name_.data(), filename_bytes};
  }

  inline bool remember(std::uint16_t port) noexcept {
    if (!ProxyPortRange::contains(port)) {
      return false;
    }

    std::array<char, maximum_record_bytes> record;
    auto *end = std::to_chars(record.data(), record.data() + record.size(), port).ptr;
    *end++ = '\n';
    end = std::copy(endpoint_.begin(), endpoint_.end(), end);
    *end++ = '\n';
    const auto bytes = std::span{reinterpret_cast<const std::uint8_t *>(record.data()), static_cast<std::size_t>(end - record.data())};
    if (writePrivateFile(directory_, filename(), bytes, PrivateFileMode::replace) != 0) {
      return false;
    }

    if (!own_ && legacy_ == port) {
      ::unlinkat(directory_, legacy_name, 0);
    }
    if (reserved_.test(port - ProxyPortRange::first)) {
      scan([&](const char *name, const Record &record) {
        if (record.port == port) {
          ::unlinkat(directory_, name, 0);
        }
      });
    }
    return true;
  }

private:
  struct Record {
    std::uint16_t port;
    std::string_view endpoint;
  };

  struct DirectoryCloser {
    inline void operator()(DIR *directory) const noexcept {
      ::closedir(directory);
    }
  };

  inline void identify(std::string_view endpoint) noexcept {
    Sha256 hash;
    hash.update(endpoint);
    const auto digest = hash.finish();
    auto *end = std::copy(file_prefix.begin(), file_prefix.end(), name_.begin());
    for (std::size_t index = 0; index < digest_bytes; ++index) {
      *end++ = hexadecimal[digest[index] >> 4];
      *end++ = hexadecimal[digest[index] & 15];
    }
    *end = '\0';
  }

  inline std::optional<Record> recall(std::string_view name, Vector<unsigned char, Memory> &bytes) const noexcept {
    try {
      if (!readPrivateFile(directory_, name, bytes, maximum_record_bytes)) {
        return std::nullopt;
      }
    } catch (...) {
      return std::nullopt;
    }

    const std::string_view text{reinterpret_cast<const char *>(bytes.data()), bytes.size()};
    const auto newline = text.find('\n');
    auto number = trimCarriageReturns(text.substr(0, newline));
    if (number.starts_with('+')) {
      number.remove_prefix(1);
    }
    if (number.empty() || number.front() == '_' || number.back() == '_') {
      return std::nullopt;
    }

    std::uint32_t port = 0;
    for (const char character : number) {
      if (character == '_') {
        continue;
      }
      if (character < '0' || character > '9') {
        return std::nullopt;
      }
      port = port * 10 + static_cast<unsigned>(character - '0');
      if (port > UINT16_MAX) {
        return std::nullopt;
      }
    }
    if (!ProxyPortRange::contains(static_cast<std::uint16_t>(port))) {
      return std::nullopt;
    }

    const auto tail = newline == std::string_view::npos ? std::string_view{} : text.substr(newline + 1);
    return Record{static_cast<std::uint16_t>(port), trimCarriageReturns(tail.substr(0, tail.find('\n')))};
  }

  template <typename Visitor>
  inline void scan(const Visitor &visit) const noexcept {
    try {
      FileDescriptor descriptor{::openat(directory_, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      if (!descriptor) {
        return;
      }
      std::unique_ptr<DIR, DirectoryCloser> directory{::fdopendir(descriptor.get())};
      if (!directory) {
        return;
      }
      descriptor.release();

      Vector<unsigned char, Memory> bytes{AllocatorRef<unsigned char, Memory>{memory_}};
      for (std::size_t scanned = 0; scanned < maximum_scanned_entries; ++scanned) {
        const auto *entry = ::readdir(directory.get());
        if (entry == nullptr) {
          return;
        }
        const std::string_view name{entry->d_name};
        if (entry->d_type != DT_REG || name == filename() || !isPortFile(name)) {
          continue;
        }
        if (const auto record = recall(name, bytes)) {
          visit(entry->d_name, *record);
        }
      }
    } catch (...) {
    }
  }

  inline static bool isPortFile(std::string_view name) noexcept {
    return name.size() == filename_bytes && name.starts_with(file_prefix) && std::ranges::all_of(name.substr(file_prefix.size()), [](char byte) { return hexadecimal.contains(byte); });
  }

  inline static bool vanished(std::string_view endpoint) noexcept {
    if (!endpoint.starts_with('/') || endpoint.contains('\0')) {
      return false;
    }

    const auto separator = endpoint.rfind('/');
    std::array<char, PATH_MAX + 1> parent;
    const auto length = std::max<std::size_t>(separator, 1);
    if (length >= parent.size()) {
      return false;
    }
    std::copy_n(endpoint.data(), length, parent.data());
    parent[length] = '\0';
    struct stat metadata{};
    return ::stat(parent.data(), &metadata) != 0 && errno == ENOENT;
  }

  inline static std::string_view trimCarriageReturns(std::string_view text) noexcept {
    while (text.ends_with('\r')) {
      text.remove_suffix(1);
    }
    return text;
  }

  static constexpr std::string_view file_prefix = "proxy-port-";
  static constexpr std::string_view hexadecimal = "0123456789abcdef";
  static constexpr char legacy_name[] = "proxy-port";
  static constexpr std::size_t digest_bytes = 8;
  static constexpr std::size_t filename_bytes = file_prefix.size() + digest_bytes * 2;
  static constexpr std::size_t maximum_scanned_entries = 4096;
  static constexpr std::size_t maximum_record_bytes = 8 + PATH_MAX + 1;
  Memory &memory_;
  int directory_;
  String<Memory> endpoint_;
  std::array<char, filename_bytes + 1> name_;
  ProxyPortRange::Set reserved_;
  std::optional<std::uint16_t> own_;
  std::optional<std::uint16_t> legacy_;
};

template <Allocator Memory>
ProxyPortMemory(Memory &memory, int directory, std::string_view endpoint, bool inherit_legacy) -> ProxyPortMemory<Memory>;

}
}

// Interface: proxy/refusal.cppm
export {
namespace telar::runtime {

class ProxyRefusal {
public:
  inline explicit ProxyRefusal(FileDescriptor socket, ProxyConnectionPolicy::Time now) noexcept
      : socket_(std::move(socket)), deadline_(now + drain_duration) {}

  inline bool advance(ProxyConnectionPolicy::Time now) noexcept {
    if (now >= deadline_) {
      return true;
    }
    SocketStream stream{socket_.get()};
    if (offset_ < response.size()) {
      const auto sent = stream.write({reinterpret_cast<const std::uint8_t *>(response.data() + offset_), response.size() - offset_});
      if (sent.state != StreamResult::State::data) {
        return sent.state != StreamResult::State::blocked;
      }
      offset_ += sent.bytes;
      if (offset_ != response.size()) {
        return false;
      }
      stream.halfClose();
    }

    std::array<std::uint8_t, 4096> discarded;
    const auto read = stream.read(discarded);
    return read.state == StreamResult::State::ended || read.state == StreamResult::State::failed;
  }

  inline int descriptor() const noexcept {
    return socket_.get();
  }

  inline SocketInterest interest() const noexcept {
    return {.readable = offset_ == response.size(), .writable = offset_ != response.size()};
  }

  inline ProxyConnectionPolicy::Time deadline() const noexcept {
    return deadline_;
  }

private:
  static constexpr auto drain_duration = std::chrono::milliseconds{20};
  static constexpr std::string_view response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  FileDescriptor socket_;
  ProxyConnectionPolicy::Time deadline_;
  std::size_t offset_ = 0;
};

}
}

// Interface: proxy/service.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory, EventLoop Poller, HostnameResolver Resolver>
class ProxyService {
public:
  inline explicit ProxyService(Memory &memory, const ProxyOptions<Memory> &options, const ProxySecret &secret, const TlsInterception<Memory> &interception, ProxyListener listener, traffic::FlowControl *flows = nullptr)
      : memory_(memory), options_(options), secret_(secret), interception_(interception), listener_(std::move(listener)), observations_(memory, options.capture, flows), poller_(memory), resolutions_(resolution_signal_), flows_(flows) {
    poller_.watch(listener_.descriptor(), listener_token);
    poller_.watch(stop_signal_.descriptor(), stop_token);
    poller_.watch(resolution_signal_.descriptor(), resolution_token);
    poller_.watch(adoption_signal_.descriptor(), adoption_token);
    if (flows_) { poller_.watch(flows_->descriptor(), flow_token); }
    worker_ = std::thread{[this] { run(); }};
  }

  inline ~ProxyService() {
    stopping_.store(true, std::memory_order_release);
    stop_signal_.notify();
    worker_.join();
  }

  ProxyService(const ProxyService &) = delete;
  ProxyService &operator=(const ProxyService &) = delete;

  inline std::uint16_t port() const noexcept {
    return listener_.port();
  }

  inline const ProxyCounters &counters() const noexcept {
    return observations_.counters;
  }

  inline CaptureProducer<Memory> &captures() noexcept {
    return observations_.captures;
  }

  inline const CaptureProducer<Memory> &captures() const noexcept {
    return observations_.captures;
  }

  inline std::uint32_t active() const noexcept {
    return active_.load(std::memory_order_relaxed);
  }

  inline std::uint64_t limitDrops() const noexcept {
    return limit_drops_.load(std::memory_order_relaxed);
  }

  inline bool failed() const noexcept {
    return failed_.load(std::memory_order_acquire);
  }

  inline bool adopt(redirect::Connection connection) noexcept {
    if (stopping_.load(std::memory_order_acquire) || failed()) {
      return false;
    }
    const bool accepted = adoptions_.publish(std::move(connection));
    if (!accepted) {
      limit_drops_.fetch_add(1, std::memory_order_relaxed);
    }
    adoption_signal_.notify();
    return accepted;
  }

private:
  using Policy = ProxyConnectionPolicy;
  using Time = Policy::Time;
  using Connection = ProxyConnection<Memory, Resolver>;

  struct Slot {
    inline explicit Slot(Owned<Connection, Memory> connection, std::uint64_t generation) noexcept
        : connection(std::move(connection)), child_generation(generation) {}

    Owned<Connection, Memory> connection;
    SocketWatch child;
    SocketWatch origin;
    std::uint64_t child_generation;
    std::uint64_t origin_generation = 0;
    std::size_t origin_attempt = 0;
  };

  inline void run() noexcept {
    setThreadName("telar.proxy");
    try {
      auto reap_at = Policy::Clock::now() + reap_interval;
      while (!stopping_.load(std::memory_order_acquire)) {
        const auto now = Policy::Clock::now();
        auto wake_at = reap_at;
        advanceRefusal(now);
        if (refusal_) {
          wake_at = std::min(wake_at, refusal_->deadline());
        } else if (accept_after_ != Time{}) {
          if (now >= accept_after_) {
            accept_after_ = {};
            poller_.readInterest(listener_.descriptor(), listener_token, true);
          } else {
            wake_at = std::min(wake_at, accept_after_);
          }
        }

        occupied_.forEach([&](std::size_t index) {
          auto &slot = slots_[index];
          if (now >= reap_at) {
            slot->connection->expire(now);
            advance(index, {}, now);
          } else if (slot->connection->buffered() || (slot->connection->deadline() && now >= *slot->connection->deadline())) {
            advance(index, TunnelReadiness::available(), now);
          }
          if (slot) {
            if (const auto deadline = slot->connection->deadline()) {
              wake_at = std::min(wake_at, *deadline);
            }
            if (slot->connection->buffered()) {
              wake_at = now;
            }
          }
        });
        if (now >= reap_at) {
          reap_at = now + reap_interval;
        }

        const auto events = poller_.wait(wake_at - Policy::Clock::now());
        for (const auto &event : events) {
          if (stopping_.load(std::memory_order_acquire)) {
            break;
          }
          dispatch(event, Policy::Clock::now());
        }
      }
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar proxy service: %s\n", error.what());
      failed_.store(true, std::memory_order_release);
    } catch (...) {
      failed_.store(true, std::memory_order_release);
    }

    refusal_watch_.remove(poller_);
    refusal_.reset();
    occupied_.forEach([this](std::size_t index) { release(index); });
    adoptions_.close();
    poller_.remove(listener_.descriptor());
    listener_.close();
  }

  inline void dispatch(const Event &event, Time now) {
    if (event.token == listener_token) {
      if (!refusal_ && accept_after_ == Time{}) {
        accept(now);
      }
    } else if (event.token == stop_token) {
      stop_signal_.drain();
    } else if (event.token == resolution_token) {
      resolution_signal_.drain();
      occupied_.forEach([&](std::size_t index) {
        if (slots_[index]->connection->policy().phase() == Policy::Phase::establishing) {
          advance(index, {}, now);
        }
      });
    } else if (event.token == flow_token) {
      flows_->drain();
      occupied_.forEach([&](std::size_t index) { advance(index, TunnelReadiness::available(), now); });
    } else if (event.token == adoption_token) {
      adoption_signal_.drain();
      while (auto connection = adoptions_.tryReceive()) {
        const auto index = admit(now, true);
        if (!index) {
          continue;
        }
        try {
          keep(makeOwned<Connection>(memory_, memory_, std::move(*connection), options_, secret_, observations_.counters), *index, now);
        } catch (...) {
          release(*index);
        }
      }
    } else if (event.token == refusal_token) {
      if (refusal_watch_.matches(event)) {
        advanceRefusal(now);
      }
    } else {
      const auto index = (event.token >> side_bits) & slot_mask;
      auto &slot = slots_[index];
      if (slot && (slot->child.matches(event) || slot->origin.matches(event))) {
        TunnelReadiness readiness;
        auto &side = slot->origin.matches(event) ? readiness.origin : readiness.child;
        side = {.readable = event.kind == EventKind::readable, .writable = event.kind == EventKind::writable};
        advance(index, readiness, now);
      }
    }
  }

  inline void accept(Time now) {
    TELAR_TRACE("proxy.acceptConnections");
    for (std::size_t accepted = 0; accepted < maximum_accept_batch; ++accepted) {
      FileDescriptor child;
      try {
        child = listener_.accept();
      } catch (const SystemError &error) {
        if (error.code() == EMFILE || error.code() == ENFILE || error.code() == ENOBUFS || error.code() == ENOMEM) {
          accept_after_ = now + descriptor_backoff;
          poller_.readInterest(listener_.descriptor(), listener_token, false);
        }
        return;
      }
      if (!child) {
        return;
      }

      const auto index = admit(now);
      if (!index) {
        refusal_.emplace(std::move(child), now);
        poller_.readInterest(listener_.descriptor(), listener_token, false);
        advanceRefusal(now);
        return;
      }
      try {
        auto connection = makeOwned<Connection>(memory_, memory_, std::move(child), options_, secret_, observations_.counters);
        keep(std::move(connection), *index, now);
      } catch (...) {
        release(*index);
      }
    }
  }

  inline void keep(Owned<Connection, Memory> connection, std::size_t index, Time now) {
    slots_[index].emplace(std::move(connection), nextGeneration());
    occupied_.insert(index);
    active_.fetch_add(1, std::memory_order_relaxed);
    advance(index, {}, now);
  }

  inline std::optional<std::size_t> admit(Time now, bool authenticated = false) noexcept {
    std::size_t unauthenticated = 0;
    occupied_.forEach([&](std::size_t index) { unauthenticated += slots_[index]->connection->policy().phase() == Policy::Phase::connect_head; });
    if (!authenticated && unauthenticated >= Policy::maximum_unauthenticated) {
      if (const auto evicted = oldest(Policy::Closure::evict_head, now)) {
        release(*evicted);
        observations_.counters.record(ProxyCounter::unauthenticated_eviction);
      } else {
        observations_.counters.record(ProxyCounter::unauthenticated_refusal);
        return std::nullopt;
      }
    }

    if (const auto available = occupied_.firstUnused()) {
      return available;
    }
    for (const auto reason : {Policy::Closure::evict_head, Policy::Closure::evict_idle, Policy::Closure::evict_silent}) {
      if (const auto evicted = oldest(reason, now)) {
        release(*evicted);
        observations_.counters.record(ProxyCounter::eviction);
        return evicted;
      }
    }
    limit_drops_.fetch_add(1, std::memory_order_relaxed);
    return std::nullopt;
  }

  inline std::optional<std::size_t> oldest(Policy::Closure reason, Time now) const noexcept {
    std::optional<std::size_t> found;
    auto since = Time::max();
    occupied_.forEach([&](std::size_t index) {
      const auto &policy = slots_[index]->connection->policy();
      const auto started = reason == Policy::Closure::evict_head ? policy.since() : policy.active();
      if (policy.evictable(reason, now) && started < since) {
        since = started;
        found = index;
      }
    });
    return found;
  }

  inline void advance(std::size_t index, TunnelReadiness readiness, Time now) noexcept {
    auto &slot = *slots_[index];
    slot.connection->advance(interception_, observations_, readiness, now);
    if (slot.connection->closed()) {
      release(index);
      return;
    }

    try {
      if (slot.origin_attempt != slot.connection->originAttempt()) {
        slot.origin_attempt = slot.connection->originAttempt();
        slot.origin_generation = nextGeneration();
      }
      slot.child.update(poller_, slot.connection->descriptor(TlsSide::child), token(index, slot.child_generation, TlsSide::child), slot.connection->interest(TlsSide::child));
      slot.origin.update(poller_, slot.connection->descriptor(TlsSide::origin), token(index, slot.origin_generation, TlsSide::origin), slot.connection->interest(TlsSide::origin));
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar proxy watch: %s\n", error.what());
      release(index);
    } catch (...) {
      release(index);
    }
  }

  inline void advanceRefusal(Time now) {
    if (!refusal_) {
      return;
    }
    if (refusal_->advance(now)) {
      refusal_watch_.remove(poller_);
      refusal_.reset();
      poller_.readInterest(listener_.descriptor(), listener_token, true);
    } else {
      refusal_watch_.update(poller_, refusal_->descriptor(), refusal_token, refusal_->interest());
    }
  }

  inline void release(std::size_t index) noexcept {
    auto &slot = slots_[index];
    if (slot) {
      slot->child.remove(poller_);
      slot->origin.remove(poller_);
      slot.reset();
      occupied_.erase(index);
      active_.fetch_sub(1, std::memory_order_relaxed);
    }
  }

  inline static std::uint64_t token(std::size_t index, std::uint64_t generation, TlsSide side) noexcept {
    return (generation << generation_shift) | (index << side_bits) | (side == TlsSide::origin ? 1 : 0);
  }

  inline std::uint64_t nextGeneration() {
    if (generation_ == (UINT64_MAX >> generation_shift)) {
      throw SystemError{"Proxy event generations exhausted", EOVERFLOW};
    }
    return ++generation_;
  }

  static constexpr std::uint64_t listener_token = 1;
  static constexpr std::uint64_t stop_token = 2;
  static constexpr std::uint64_t resolution_token = 3;
  static constexpr std::uint64_t refusal_token = 4;
  static constexpr std::uint64_t adoption_token = 5;
  static constexpr std::uint64_t flow_token = 6;
  static constexpr unsigned side_bits = 1;
  static constexpr unsigned slot_bits = 8;
  static constexpr unsigned generation_shift = slot_bits + side_bits;
  static constexpr std::size_t slot_mask = Policy::capacity - 1;
  static constexpr std::size_t maximum_accept_batch = 32;
  static constexpr auto reap_interval = std::chrono::seconds{1};
  static constexpr auto descriptor_backoff = std::chrono::milliseconds{100};
  static_assert(Policy::capacity == 1 << slot_bits);

  Memory &memory_;
  const ProxyOptions<Memory> &options_;
  const ProxySecret &secret_;
  const TlsInterception<Memory> &interception_;
  ProxyListener listener_;
  ProxyObservations<Memory> observations_;
  Poller poller_;
  CompletionSignal stop_signal_;
  CompletionSignal resolution_signal_;
  CompletionSignal adoption_signal_;
  DropChannel<redirect::Connection, 32> adoptions_;
  typename NameResolutions<Resolver>::Notifications resolutions_;
  traffic::FlowControl *flows_;
  std::array<std::optional<Slot>, Policy::capacity> slots_;
  SlotIndexes<Policy::capacity> occupied_;
  std::optional<ProxyRefusal> refusal_;
  SocketWatch refusal_watch_;
  Time accept_after_{};
  std::uint64_t generation_ = 0;
  std::atomic<std::uint32_t> active_ = 0;
  std::atomic<std::uint64_t> limit_drops_ = 0;
  std::atomic<bool> stopping_ = false;
  std::atomic<bool> failed_ = false;
  std::thread worker_;
};

}
}

// Interface: proxy/runtime.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory, EventLoop Poller, HostnameResolver Resolver, typename Tap = IgnoreCaptureTap>
  requires CaptureTap<Tap, Memory>
class ProxyRuntime {
public:
  inline explicit ProxyRuntime(Memory &memory, const ProxyOptions<Memory> &options, std::string_view endpoint, bool inherit_legacy)
    requires std::same_as<Tap, IgnoreCaptureTap>
      : ProxyRuntime(memory, options, endpoint, inherit_legacy, ignored_tap_) {}

  inline explicit ProxyRuntime(Memory &memory, const ProxyOptions<Memory> &options, std::string_view endpoint, bool inherit_legacy, Tap &tap)
      : memory_(memory), authority_directory_(directoryPath(memory, options)), certificate_path_(AllocatorRef<char, Memory>{memory}), bundle_path_(AllocatorRef<char, Memory>{memory}) {
    TELAR_TRACE("proxy.startRuntime");
    const auto &path = authority_directory_;
    const proxy_trust::Paths trust_paths{memory, path};
    struct stat record_state{};
    const auto record_path = trust_paths.file(proxy_trust::Record::filename);
    const bool has_trust_record = ::lstat(record_path.c_str(), &record_state) == 0;
    if (!options.enabled && !has_trust_record) {
      return;
    }

    library_.emplace(memory);
    const auto destination = trust_paths.nativeDestination(memory, ProcessEnvironment{});
    proxy_trust::SystemCommand trust_command{memory, stderr};
    proxy_trust::Service system_trust{memory, *library_, trust_paths, trust_command, destination};
    if (const auto rotated = system_trust.rotateIfNeeded()) {
      std::fprintf(stderr, "telar proxy trust: installed %.*s\n", static_cast<int>(rotated->fingerprint.size()), rotated->fingerprint.data());
    }

    const bool system_trusted = system_trust.inspect().status == proxy_trust::Status::installed;
    if (!options.enabled) {
      return;
    }

    raiseDescriptorLimit();
    createPrivateDirectory(path);
    FileDescriptor directory{::open(path.c_str(), O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)};
    if (!directory) {
      throw SystemError{"Open proxy authority directory"};
    }

    const auto authority_kind = system_trusted ? AuthorityKind::system_trust : AuthorityKind::private_local;
    auto authority = std::allocate_shared<CertificateAuthority<Memory>>(AllocatorRef<CertificateAuthority<Memory>, Memory>{memory}, CertificateAuthority<Memory>::loadOrCreate(memory, *library_, directory.get(), authority_kind));
    publishAuthority(*authority, directory.get());
    trust_.emplace(memory, *library_);
    SystemCertificates::read([this](std::span<const std::uint8_t> bytes) { trust_->addDer(bytes); });
    contexts_.emplace(memory, *library_, *trust_);
    interception_.emplace(*contexts_, std::move(authority));
    secret_.emplace(ProxySecretFile::ensure(memory, directory.get()));
    ProxyPortMemory ports{memory, directory.get(), endpoint, inherit_legacy};
    auto listener = ProxyListener::bind(ports.preferred(), ports.reserved());
    ports.remember(listener.port());

    certificate_path_ = path;
    certificate_path_ += '/';
    certificate_path_ += active_certificate;
    bundle_path_ = path;
    bundle_path_ += "/ca-bundle.pem";
    status_.active = true;
    status_.system_trusted = system_trusted;
    status_.port = listener.port();
    status_.preferred_port = ports.preferred();
    status_.scope = std::ranges::any_of(options.intercept_hosts.patterns(), [](const auto &host) { return host.starts_with('*'); }) ? ProxyScope::wildcard : ProxyScope::exact;
    service_.emplace(memory, options, *secret_, *interception_, std::move(listener), flowControl(tap));
    if (options.transparent_redirect) {
      String<Memory> redirect_path{endpoint, AllocatorRef<char, Memory>{memory}};
      redirect_path += redirect::socket_suffix;
      redirect_.emplace(redirect_path, *service_);
    }
    if (options.capture.enabled) {
      captures_.emplace(memory, service_->captures(), options.capture, tap);
    }
  }

  inline ProxyClientConfiguration clientConfiguration() const noexcept {
    return secret_ ? ProxyClientConfiguration{status_, *secret_, certificate_path_, bundle_path_} : ProxyClientConfiguration{};
  }

  inline int descriptor() const noexcept { return captures_ ? captures_->descriptor() : -1; }
  inline bool collect() noexcept { return captures_ && captures_->collect(); }

  inline CaptureMetrics captureMetrics() const noexcept {
    return service_ ? service_->captures().metrics() : CaptureMetrics{};
  }

  inline ProxyMetrics proxyMetrics() const noexcept {
    if (!service_) {
      return {};
    }

    return {service_->counters().snapshot(), service_->active(), service_->limitDrops()};
  }

  inline redirect::MonitorState redirectStatus() const noexcept { return redirect_ ? redirect_->status() : redirect::MonitorState::idle; }
  inline void stopRedirect() noexcept { if (redirect_) { redirect_->stop(); } }

  struct AuthorityStatus {
    bool active = false;
    bool accepting = false;
    proxy_trust::Status trust = proxy_trust::Status::absent;
    std::array<char, 40> fingerprint_sha1{};
    std::array<char, 64> fingerprint_sha256{};
    std::array<Byte, PemDocument::maximum_bytes> certificate{};
    std::size_t certificate_bytes = 0;
  };

  inline AuthorityStatus authorityStatus(bool include_certificate = false) const {
    AuthorityStatus result;
    if (!interception_) { return result; }
    const proxy_trust::Paths paths{memory_, authority_directory_};
    const auto destination = paths.nativeDestination(memory_, ProcessEnvironment{});
    const auto inspection = proxy_trust::inspect(memory_, *library_, paths, destination);
    const auto current = interception_->snapshot();
    requireTls(current != nullptr, "TLS authority is unavailable");
    const auto &authority = *current;
    result.active = true;
    result.accepting = !interception_->suspended();
    result.trust = inspection.status;
    result.fingerprint_sha1 = authority.fingerprint();
    result.fingerprint_sha256 = authority.fingerprintSha256();
    if (inspection.record && inspection.record->fingerprint != result.fingerprint_sha1) { result.trust = proxy_trust::Status::stale; }
    if (include_certificate) {
      const PemDocument certificate{authority.certificate()};
      std::ranges::copy(certificate.bytes(), result.certificate.begin());
      result.certificate_bytes = certificate.bytes().size();
    }
    return result;
  }

  // Keep each handshake's signer alive independently. If store or file updates
  // fail, new TLS sessions remain suspended until an explicit retry synchronizes
  // the signer and the stable trust files used by newly launched processes.
  template <proxy_trust::TrustCommandExecutor Executor>
  inline void manageAuthority(proxy_trust::Action action, Executor &executor) {
    if (!interception_) { throw std::invalid_argument{"Proxy TLS is disabled"}; }
    const proxy_trust::Paths paths{memory_, authority_directory_};
    const auto destination = paths.nativeDestination(memory_, ProcessEnvironment{});
    proxy_trust::Service trust{memory_, *library_, paths, executor, destination};
    const auto previous = trust.inspect();
    if (previous.status == proxy_trust::Status::stale && !previous.record) { throw std::invalid_argument{"Proxy trust record is invalid"}; }
    interception_->suspend(true);
    const auto directory = paths.prepare();
    auto kind = AuthorityKind::private_local;
    if (action == proxy_trust::Action::uninstall) {
      if (previous.record) { trust.uninstall(*previous.record); }
    } else if (action == proxy_trust::Action::install || previous.record) {
      trust.install(previous.record, action == proxy_trust::Action::rotate);
      kind = AuthorityKind::system_trust;
    } else {
      proxy_trust::PreparedAuthority prepared{memory_, *library_, directory.get(), proxy_trust::AuthorityPreparation{.kind = AuthorityKind::private_local, .force_rotation = true}};
      prepared.activate();
      prepared.commit();
    }
    auto authority = std::allocate_shared<CertificateAuthority<Memory>>(AllocatorRef<CertificateAuthority<Memory>, Memory>{memory_}, CertificateAuthority<Memory>::loadOrCreate(memory_, *library_, directory.get(), kind));
    publishAuthority(*authority, directory.get());
    interception_->replace(std::move(authority));
    interception_->suspend(false);
  }

private:
  static constexpr std::string_view active_certificate = "ca-active-cert.pem";

  inline void publishAuthority(const CertificateAuthority<Memory> &authority, int directory) {
    const PemDocument certificate{authority.certificate()};
    if (const auto error = writePrivateFile(directory, active_certificate, certificate.bytes(), PrivateFileMode::replace)) { throw SystemError{"Publish active TLS certificate", error}; }
    authority.writeBundle(directory, SystemRootBundle{memory_}.bytes());
  }

  inline static traffic::FlowControl *flowControl(Tap &tap) noexcept {
    if constexpr (requires { tap.flowControl(); }) {
      return tap.flowControl();
    }
    return nullptr;
  }

  inline static String<Memory> directoryPath(Memory &memory, const ProxyOptions<Memory> &options) {
    if (!options.authority_directory.empty()) {
      return options.authority_directory;
    }

    return proxyAuthorityDirectory(memory, ProcessEnvironment{});
  }

  inline static void raiseDescriptorLimit() noexcept {
    constexpr rlim_t descriptors_per_connection = 2;
    constexpr rlim_t reserved_descriptors = 448;
    constexpr rlim_t wanted = ProxyConnectionPolicy::capacity * descriptors_per_connection + NameResolutions<Resolver>::capacity + reserved_descriptors;
    static_assert(wanted == 1024);
    rlimit limit;
    if (::getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < wanted) {
      limit.rlim_cur = std::min(limit.rlim_max, wanted);
      ::setrlimit(RLIMIT_NOFILE, &limit);
    }
  }

  Memory &memory_;
  String<Memory> authority_directory_;
  String<Memory> certificate_path_;
  String<Memory> bundle_path_;
  ProxyStatus status_{};
  std::optional<TlsLibrary<Memory>> library_;
  std::optional<TlsTrustStore<Memory>> trust_;
  std::optional<TlsContexts<Memory>> contexts_;
  std::optional<TlsInterception<Memory>> interception_;
  std::optional<ProxySecret> secret_;
  std::optional<ProxyService<Memory, Poller, Resolver>> service_;
  std::optional<CapturePipeline<Memory, Tap>> captures_;
  std::optional<redirect::Ingress<ProxyService<Memory, Poller, Resolver>>> redirect_;
  inline static IgnoreCaptureTap ignored_tap_;
};

}
}
