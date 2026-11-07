module;
#include <chrono>
#include <limits>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#include <cstdint>
#include <cstring>
#include <netinet/in.h>
#include <optional>
#include <sys/socket.h>

#include <cerrno>
#include <netdb.h>
#include <span>

#include <pthread.h>
#include <exception>
#include <array>
#include <string_view>
#include <algorithm>
#include <arpa/inet.h>
#include <cstddef>
#include <concepts>
#include <type_traits>
#include <utility>

#include <csignal>
#include <netinet/tcp.h>

#include <unistd.h>

export module telar.runtime.proxy.relay_direction;

export import telar.platform;
export import telar.runtime.platform.signals;

export import telar.config;


export import telar.runtime.platform.stream_read_buffer;
import telar.base.diagnostics;
import telar.platform.primitives;

// Interface: proxy/network_address.cppm
export {
namespace telar::runtime {

struct NetworkAddress {
  sockaddr_storage storage{};
  socklen_t length = 0;

  inline static std::optional<NetworkAddress> copy(const sockaddr *source, socklen_t size) noexcept {
    if (source == nullptr || (source->sa_family != AF_INET && source->sa_family != AF_INET6)) {
      return std::nullopt;
    }
    const auto expected = source->sa_family == AF_INET ? sizeof(sockaddr_in) : sizeof(sockaddr_in6);
    if (size < expected) {
      return std::nullopt;
    }

    NetworkAddress address;
    address.length = static_cast<socklen_t>(expected);
    std::memcpy(&address.storage, source, expected);
    address.setPort(0);
    return address;
  }

  inline void setPort(std::uint16_t port) noexcept {
    if (storage.ss_family == AF_INET) {
      reinterpret_cast<sockaddr_in *>(&storage)->sin_port = htons(port);
    } else if (storage.ss_family == AF_INET6) {
      reinterpret_cast<sockaddr_in6 *>(&storage)->sin6_port = htons(port);
    }
  }

  inline const sockaddr *address() const noexcept {
    return reinterpret_cast<const sockaddr *>(&storage);
  }
};

}
}

// Interface: proxy/system_resolver.cppm
export {
namespace telar::runtime {

struct ResolutionSummary {
  std::size_t found = 0;
  int error = 0;
};

class SystemNameResolver {
public:
  inline static ResolutionSummary resolve(const char *hostname, std::span<NetworkAddress> addresses) noexcept {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    addrinfo *entries = nullptr;
    int error;
    do {
      error = ::getaddrinfo(hostname, nullptr, &hints, &entries);
    } while (error == EAI_SYSTEM && errno == EINTR);
    if (error != 0) {
      return {.error = error};
    }

    std::size_t found = 0;
    for (const auto *entry = entries; entry != nullptr; entry = entry->ai_next) {
      const auto address = NetworkAddress::copy(entry->ai_addr, entry->ai_addrlen);
      if (!address) {
        continue;
      }
      if (found < addresses.size()) {
        addresses[found] = *address;
      }
      ++found;
    }
    ::freeaddrinfo(entries);
    return {.found = found};
  }
};

}
}

// Interface: proxy/name_resolutions.cppm
export {
namespace telar::runtime {

template <typename Resolver>
concept HostnameResolver = requires(const char *hostname, std::span<NetworkAddress> addresses) {
  { Resolver::resolve(hostname, addresses) } noexcept -> std::same_as<ResolutionSummary>;
};

template <HostnameResolver Resolver>
class NameResolutions {
public:
  static constexpr std::size_t capacity = 64;
  static constexpr std::size_t maximum_addresses = 32;

  struct Result {
    std::array<NetworkAddress, maximum_addresses> addresses;
    ResolutionSummary summary;
  };

private:
  enum class Phase {
    free,
    resolving,
    resolved
  };

  struct Row {
    Phase phase = Phase::free;
    std::array<char, ProxyHostname::maximum_bytes + 1> hostname{};
    std::size_t length = 0;
    std::size_t waiters = 0;
    Result result;
  };

  static constexpr std::size_t maximum_subscribers = 128;

  struct State {
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    std::array<Row, capacity> rows;
    std::array<CompletionSignal *, maximum_subscribers> subscribers{};
  };

  class Lock {
  public:
    inline Lock() noexcept {
      ::pthread_mutex_lock(&state_.mutex);
    }

    inline ~Lock() {
      ::pthread_mutex_unlock(&state_.mutex);
    }

    Lock(const Lock &) = delete;
    Lock &operator=(const Lock &) = delete;
  };

public:
  class Ticket {
  public:
    inline ~Ticket() {
      reset();
    }

    Ticket(const Ticket &) = delete;
    Ticket &operator=(const Ticket &) = delete;

    inline Ticket(Ticket &&other) noexcept
        : index_(std::exchange(other.index_, capacity)) {}

    Ticket &operator=(Ticket &&other) noexcept {
      if (this != &other) {
        reset();
        index_ = std::exchange(other.index_, capacity);
      }
      return *this;
    }

    inline bool collect(Result &result) const noexcept {
      const Lock lock;
      if (index_ == capacity || state_.rows[index_].phase != Phase::resolved) {
        return false;
      }

      const auto &stored = state_.rows[index_].result;
      result.summary = stored.summary;
      if (stored.summary.error == 0) {
        std::copy_n(stored.addresses.begin(), std::min(stored.summary.found, maximum_addresses), result.addresses.begin());
      }
      return true;
    }

    inline void reset() noexcept {
      if (index_ == capacity) {
        return;
      }

      const Lock lock;
      auto &row = state_.rows[std::exchange(index_, capacity)];
      if (--row.waiters == 0 && row.phase == Phase::resolved) {
        row.phase = Phase::free;
      }
    }

  private:
    friend class NameResolutions;

    inline explicit Ticket(std::size_t index) noexcept
        : index_(index) {}

    std::size_t index_;
  };

  class Notifications {
  public:
    inline explicit Notifications(CompletionSignal &signal) {
      const Lock lock;
      const auto available = std::ranges::find(state_.subscribers, nullptr);
      if (available == state_.subscribers.end()) {
        throw SystemError{"Too many proxy resolver subscribers", ENOSPC};
      }
      *available = &signal;
      index_ = static_cast<std::size_t>(available - state_.subscribers.begin());
    }

    inline ~Notifications() {
      const Lock lock;
      state_.subscribers[index_] = nullptr;
    }

    Notifications(const Notifications &) = delete;
    Notifications &operator=(const Notifications &) = delete;

  private:
    std::size_t index_;
  };

  inline static std::optional<Ticket> request(std::string_view hostname) noexcept {
    if (!ProxyHostname::validTarget(hostname)) {
      return std::nullopt;
    }

    const Lock lock;
    std::optional<std::size_t> available;
    for (std::size_t index = 0; index < state_.rows.size(); ++index) {
      auto &row = state_.rows[index];
      if (row.phase == Phase::free) {
        if (!available) {
          available = index;
        }
      } else if (row.length == hostname.size() && std::equal(hostname.begin(), hostname.end(), row.hostname.begin(), [](char first, char second) { return asciiLower(first) == asciiLower(second); })) {
        ++row.waiters;
        return Ticket{index};
      }
    }
    if (!available) {
      return std::nullopt;
    }

    auto &row = state_.rows[*available];
    row.phase = Phase::resolving;
    row.length = hostname.size();
    std::copy(hostname.begin(), hostname.end(), row.hostname.begin());
    row.hostname[row.length] = '\0';
    row.waiters = 1;
    if (const auto error = start(row); error != 0) {
      row.result.summary = {.error = EAI_MEMORY};
      row.phase = Phase::resolved;
      notify();
    }
    return Ticket{*available};
  }

  inline static std::size_t pending() noexcept {
    const Lock lock;
    return std::ranges::count_if(state_.rows, [](const auto &row) { return row.phase == Phase::resolving; });
  }

private:
  inline static int start(Row &row) noexcept {
    pthread_attr_t attributes;
    const int initialized = ::pthread_attr_init(&attributes);
    if (initialized != 0) {
      return initialized;
    }

    int error = ::pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    if (error == 0) {
      error = ::pthread_attr_setstacksize(&attributes, worker_stack_bytes);
    }
    if (error == 0) {
      pthread_t thread;
      error = ::pthread_create(&thread, &attributes, &resolve, &row);
    }
    ::pthread_attr_destroy(&attributes);
    return error;
  }

  inline static void *resolve(void *context) noexcept {
    setThreadName("telar.proxy.dns");
    auto &row = *static_cast<Row *>(context);
#if TELAR_DEBUG
    const auto started = trace::now();
#endif
    const auto summary = Resolver::resolve(row.hostname.data(), row.result.addresses);
    const Lock lock;
    if (row.waiters == 0) {
      row.phase = Phase::free;
      return nullptr;
    }

    row.result.summary = summary;
    row.phase = Phase::resolved;
#if TELAR_DEBUG
    trace::record("proxy.resolveHostname", started, trace::now());
#endif
    notify();
    return nullptr;
  }

  inline static void notify() noexcept {
    for (auto *subscriber : state_.subscribers) {
      if (subscriber != nullptr) {
        subscriber->notify();
      }
    }
  }

  static constexpr std::size_t worker_stack_bytes = 512 * 1024;
  // Detached system resolver calls may outlive every proxy. Their rows have
  // process lifetime and never borrow a runtime allocator or service object.
  inline static constinit State state_;
  static_assert(std::is_trivially_destructible_v<State>);
};

}
}

// Interface: proxy/socket.cppm
export {
namespace telar::runtime {

inline bool socketWouldBlock(int error) noexcept {
  return error == EAGAIN || error == EWOULDBLOCK || error == EINTR;
}

inline void configureProxySocket(int socket) {
  setCloseOnExec(socket);
  setNonblocking(socket);
  suppressSocketSignals(socket);
}

inline FileDescriptor openOriginSocket(int family) {
  FileDescriptor socket{::socket(family, SOCK_STREAM, IPPROTO_TCP)};
  if (!socket) {
    throw SystemError{"Create proxy origin socket"};
  }
  configureProxySocket(socket.get());

  struct Option {
    int level;
    int name;
    int value;
  };
  constexpr int enabled = 1;
  constexpr int idle_seconds = 60;
  constexpr int interval_seconds = 10;
  constexpr int probe_count = 6;
#if defined(__APPLE__)
  constexpr int idle_option = TCP_KEEPALIVE;
#else
  constexpr int idle_option = TCP_KEEPIDLE;
#endif
  constexpr Option options[] = {{SOL_SOCKET, SO_KEEPALIVE, enabled}, {IPPROTO_TCP, idle_option, idle_seconds}, {IPPROTO_TCP, TCP_KEEPINTVL, interval_seconds}, {IPPROTO_TCP, TCP_KEEPCNT, probe_count}};
  for (const auto &option : options) {
    if (::setsockopt(socket.get(), option.level, option.name, &option.value, sizeof(option.value)) != 0) {
      throw SystemError{"Configure proxy origin keepalive"};
    }
  }
  return socket;
}

}
}

// Interface: proxy/origin_connection.cppm
export {
namespace telar::runtime {

template <HostnameResolver Resolver>
class OriginConnection {
public:
  enum class State {
    resolving,
    connecting,
    connected,
    failed,
    resolution_refused
  };

  inline explicit OriginConnection(std::string_view hostname, std::uint16_t port) noexcept
      : port_(port) {
    if (!ProxyHostname::validTarget(hostname)) {
      state_ = State::failed;
      return;
    }

    std::array<char, ProxyHostname::maximum_bytes + 1> terminated{};
    std::copy(hostname.begin(), hostname.end(), terminated.begin());
    sockaddr_in numeric{};
#if defined(__APPLE__)
    numeric.sin_len = sizeof(numeric);
#endif
    numeric.sin_family = AF_INET;
    if (::inet_pton(AF_INET, terminated.data(), &numeric.sin_addr) == 1) {
      resolved_.addresses.front() = *NetworkAddress::copy(reinterpret_cast<const sockaddr *>(&numeric), sizeof(numeric));
      resolved_.summary = {.found = 1, .error = 0};
      attemptNext();
      return;
    }

    resolution_ = Resolutions::request(hostname);
    if (!resolution_) {
      state_ = State::resolution_refused;
    }
  }

  inline State advance(bool writable) noexcept {
    if (state_ == State::resolving) {
      if (!resolution_->collect(resolved_)) {
        return state_;
      }
      resolution_.reset();
      if (resolved_.summary.error != 0) {
        state_ = State::failed;
      } else {
        attemptNext();
      }
    } else if (state_ == State::connecting && writable) {
      int failure = 0;
      socklen_t length = sizeof(failure);
      if (::getsockopt(socket_.get(), SOL_SOCKET, SO_ERROR, &failure, &length) == 0 && failure == 0) {
        state_ = State::connected;
      } else {
        attemptNext();
      }
    }
    return state_;
  }

  inline State state() const noexcept {
    return state_;
  }

  inline int descriptor() const noexcept {
    return socket_.get();
  }

  inline std::size_t attempt() const noexcept {
    return next_address_;
  }

  inline bool truncated() const noexcept {
    return resolved_.summary.found > Resolutions::maximum_addresses;
  }

private:
  using Resolutions = NameResolutions<Resolver>;

  inline void attemptNext() noexcept {
    socket_.reset();
    const auto count = std::min(resolved_.summary.found, Resolutions::maximum_addresses);
    while (next_address_ < count) {
      auto &address = resolved_.addresses[next_address_++];
      address.setPort(port_);
      try {
        socket_ = openOriginSocket(address.storage.ss_family);
      } catch (...) {
        continue;
      }

      if (::connect(socket_.get(), address.address(), address.length) == 0) {
        state_ = State::connected;
        return;
      }
      if (errno == EINPROGRESS || errno == EINTR) {
        state_ = State::connecting;
        return;
      }
      socket_.reset();
    }
    state_ = State::failed;
  }

  std::uint16_t port_;
  State state_ = State::resolving;
  FileDescriptor socket_;
  std::optional<typename Resolutions::Ticket> resolution_;
  typename Resolutions::Result resolved_{};
  std::size_t next_address_ = 0;
};

}
}

// Interface: proxy/socket_stream.cppm
export {
namespace telar::runtime {

class SocketStream {
public:
  inline explicit SocketStream(int descriptor) noexcept : descriptor_(descriptor) {}

  inline StreamResult read(std::span<std::uint8_t> destination) noexcept {
    const auto received = ::read(descriptor_, destination.data(), destination.size());
    return result(received, StreamReadiness::readable);
  }

  inline StreamResult peek(std::span<std::uint8_t> destination) noexcept {
    return result(::recv(descriptor_, destination.data(), destination.size(), MSG_PEEK), StreamReadiness::readable);
  }

  inline StreamResult write(std::span<const std::uint8_t> bytes) noexcept {
    const auto sent = ::write(descriptor_, bytes.data(), bytes.size());
    return result(sent, StreamReadiness::writable);
  }

  inline void halfClose() noexcept {
    ::shutdown(descriptor_, SHUT_WR);
  }

private:
  inline static StreamResult result(ssize_t count, StreamReadiness waiting) noexcept {
    if (count > 0) {
      return {StreamResult::State::data, static_cast<std::size_t>(count)};
    }
    if (count == 0) {
      return {StreamResult::State::ended};
    }
    return socketWouldBlock(errno) ? StreamResult{StreamResult::State::blocked, 0, waiting} : StreamResult{StreamResult::State::failed};
  }

  int descriptor_;
};

static_assert(ByteStream<SocketStream>);
static_assert(PeekableByteStream<SocketStream>);

}
}

// Interface: proxy/relay_direction.cppm
export {
namespace telar::runtime {

template <std::size_t BufferCapacity = 16 * 1024>
class RelayDirection {
  static_assert(BufferCapacity != 0);

public:
  enum class Observation { received,
                           forwarded };
  static constexpr std::size_t capacity = BufferCapacity;
  struct Progress {
    std::size_t read = 0;
    std::size_t written = 0;

    inline bool active() const noexcept {
      return read != 0 || written != 0;
    }
  };

  inline Progress advance(int source, int destination) noexcept {
    SocketStream incoming{source};
    SocketStream outgoing{destination};
    return advance(incoming, outgoing);
  }

  template <ByteStream Source, ByteStream Destination>
  inline Progress advance(Source &source, Destination &destination) noexcept {
    return advance(source, destination, [](Observation, std::span<const std::uint8_t>) noexcept {});
  }

  template <ByteStream Source, ByteStream Destination, typename Observer>
    requires requires(Observer observe, Observation stage, std::span<const std::uint8_t> bytes) {
      { observe(stage, bytes) } noexcept -> std::same_as<void>;
    }
  inline Progress advance(Source &source, Destination &destination, Observer observe) noexcept {
    Progress progress;
    if (wantsRead()) {
      const auto received = source.read(bytes_);
      if (received.state == StreamResult::State::data) {
        length_ = received.bytes;
        progress.read = length_;
        read_waiting_ = StreamReadiness::readable;
        observe(Observation::received, std::span{bytes_}.first(length_));
      } else if (received.state == StreamResult::State::blocked) {
        read_waiting_ = received.waiting;
      } else {
        ended_ = true;
      }
    }

    if (wantsWrite()) {
      const auto sent = destination.write(std::span{bytes_}.subspan(offset_, length_ - offset_));
      if (sent.state == StreamResult::State::data) {
        progress.written = sent.bytes;
        offset_ += progress.written;
        write_waiting_ = StreamReadiness::writable;
        if (offset_ == length_) {
          observe(Observation::forwarded, std::span{bytes_}.first(length_));
          offset_ = 0;
          length_ = 0;
        }
      } else if (sent.state == StreamResult::State::blocked) {
        write_waiting_ = sent.waiting;
      } else {
        ended_ = true;
        offset_ = 0;
        length_ = 0;
      }
    }

    if (finished() && !shutdown_) {
      destination.halfClose();
      shutdown_ = true;
    }
    return progress;
  }

  inline bool wantsRead() const noexcept {
    return !ended_ && length_ == 0;
  }

  inline bool wantsWrite() const noexcept {
    return length_ != 0;
  }

  inline bool finished() const noexcept {
    return ended_ && length_ == 0;
  }

  inline StreamReadiness sourceInterest() const noexcept {
    return wantsRead() ? read_waiting_ : StreamReadiness::none;
  }

  inline StreamReadiness destinationInterest() const noexcept {
    return wantsWrite() ? write_waiting_ : StreamReadiness::none;
  }

private:
  std::array<std::uint8_t, capacity> bytes_;
  std::size_t offset_ = 0;
  std::size_t length_ = 0;
  StreamReadiness read_waiting_ = StreamReadiness::readable;
  StreamReadiness write_waiting_ = StreamReadiness::writable;
  bool ended_ = false;
  bool shutdown_ = false;
};

}
}
