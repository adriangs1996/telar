module;
#include "tbc/annotations.hpp"

export module telar.runtime.redirect.ingress;

import std;
import telar.native.pcap;
import telar.sys.socket;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.platform.name_resolutions;

import telar.runtime.platform.private_tunnel;

import telar.platform.net;
import telar.runtime.platform.local_listener;

import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.client;
import telar.platform.error;
import telar.runtime.vocabulary.frames;
import telar.base.text;
import telar.base.memory.containers;
import telar.runtime.platform.signals;
import telar.base.ds;

// Interface: redirect/bytes.cppm
export {
  namespace telar::runtime::redirect {

    // Whether `bits` carries any of `flags`, as poll's revents and the kernel's flag words carry
    // them; the bits are tested unsigned. A flag is an int or, as glibc declares MSG_CTRUNC and
    // IFF_UP, an enumerator.
    template <std::integral Bits, typename... Flag>
      requires((std::integral<Flag> || std::is_enum_v<Flag>) && ...)
    constexpr bool anyFlag(Bits bits, Flag... flags) noexcept {
      return (static_cast<unsigned>(bits) & (0U | ... | static_cast<unsigned>(flags))) != 0;
    }

    // A trivially copyable value read from the front of `bytes`, as the kernel and the C interfaces
    // lay it out: a copy of constant size, which compiles to loads, rather than a cast. Bytes too
    // few to hold it are a bug, which stops the process.
    template <typename Value>
    TBC_GENERIC Value loadValue(std::span<const std::byte> bytes) noexcept {
      static_assert(std::is_trivially_copyable_v<Value>);

      if (bytes.size() < sizeof(Value)) {
        std::abort();
      }

      Value value{};

      std::ranges::copy(bytes.first(sizeof(Value)), std::as_writable_bytes(std::span{&value, 1}).begin());
      return value;
    }

    // Writes `value` over the front of `bytes`, which must hold it.
    template <typename Value>
    TBC_GENERIC void storeValue(std::span<std::byte> bytes, const Value& value) noexcept {
      static_assert(std::is_trivially_copyable_v<Value>);

      if (bytes.size() < sizeof(Value)) {
        std::abort();
      }

      std::ranges::copy(std::as_bytes(std::span{&value, 1}), bytes.begin());
    }

    // The address a sockaddr_storage holds, in the layout of its family's sockaddr.
    template <typename Address>
    TBC_GENERIC Address addressAs(const sockaddr_storage& storage) noexcept {
      return loadValue<Address>(std::as_bytes(std::span{&storage, 1}));
    }

    // Whether two values of one size hold the same bytes, as memcmp compares them.
    template <typename Left, typename Right>
    TBC_GENERIC bool sameBytes(const Left& left, const Right& right) noexcept {
      static_assert(sizeof(Left) == sizeof(Right));

      return std::ranges::equal(std::as_bytes(std::span{&left, 1}), std::as_bytes(std::span{&right, 1}));
    }

    enum class SocketEnd : std::uint8_t {
      local,
      peer,
    };

    // The address at one end of a socket, as getsockname and getpeername report it; none, with
    // errno saying why, when the socket has no such end.
    ds::Option<sockaddr_storage> socketAddress(int socket, SocketEnd end) noexcept;

    // `host:port` written into `output`, an IPv6 host in brackets; empty when it does not fit.
    tbc::val_a<std::string_view> formatAuthority(tbc::val_a<std::span<char>> output, std::string_view host, std::uint16_t port);

    inline constexpr std::size_t error_line_bytes = 2048;

    // Writes one formatted line to stderr, cut at error_line_bytes, without allocating, throwing
    // or stdio's shared state: a failed write is dropped, as fprintf drops it.
    template <typename... Arguments>
    TBC_GENERIC void writeErrorLine(std::format_string<Arguments...> format, Arguments&&... arguments) noexcept {
      ds::Array<char, error_line_bytes> line{};
      const auto written = std::format_to_n(line.dataMut(), static_cast<std::ptrdiff_t>(line.size() - 1), format, std::forward<Arguments>(arguments)...);
      const auto length = std::min(static_cast<std::size_t>(written.size), line.size() - 1);

      line.atMut(length) = '\n';
      static_cast<void>(::write(STDERR_FILENO, line.data(), length + 1));
    }

  }
}

// Interface: redirect/target.cppm
export {
  namespace telar::runtime::redirect {

    struct Target {
      static constexpr std::size_t maximum_targets = 16;
      FixedText<INET6_ADDRSTRLEN> host;
      NetworkAddress endpoint;
      std::uint16_t port = 0;

      static ProxyTarget authority(std::string_view text);

      static Target parse(std::string_view text);
    };

  }
}

// Interface: redirect/connection.cppm
export {
  namespace telar::runtime::redirect {

    struct Connection {
      FileDescriptor child;
      FileDescriptor origin;
      Target target;
      FileDescriptor lifetime{}; // NOLINT(readability-redundant-member-init): the default constructor is explicit, so a designated initializer that leaves the member out needs this one
    };

  }
}

// Interface: redirect/discovery.cppm
export {
  namespace telar::runtime::redirect {

    class Discovery {
    public:
      Discovery();

      [[nodiscard]] int descriptor() const noexcept;

      [[nodiscard]] std::string_view name() const noexcept;

      tbc::val_a<std::span<Byte>> receive(tbc::val_a<std::span<Byte>> bytes);

      void inject(std::span<Byte> frame);

    private:
      PrivateTunnel tunnel_;
      std::unique_ptr<pcap_t, decltype(&pcap_close)> injection_;
    };

  }
}

// Interface: redirect/protocol.cppm
export {
  namespace telar::runtime::redirect {

    inline constexpr std::string_view socket_suffix = ".redirect";
    enum class Kind : Byte {
      monitor = 1,
      connection = 2,
    };
    enum class MonitorState : Byte {
      idle,
      starting,
      active,
      stopping,
      cleanup_required,
    };
    enum class MonitorUpdate : Byte {
      active = 1,
      stopped = 2,
    };
    inline constexpr Byte stop_request = 1;

    class Protocol {
    public:
      static constexpr std::uint32_t magic = 0x31524454;
      static constexpr std::size_t frame_bytes = 128;
      static constexpr std::size_t descriptor_count = 2;
      static constexpr std::size_t header_bytes = sizeof(std::uint32_t) + sizeof(Byte) + sizeof(std::uint32_t);
      static constexpr std::size_t tail_bytes = sizeof(std::uint16_t);

      static tbc::val_a<std::span<const Byte>> encode(tbc::val_a<std::span<Byte>> output, Kind kind, const Target& target);

      static void send(int channel, const Connection& connection);
    };

    // Descriptors are adopted immediately, including on malformed/truncated frames.
    // A failed decode therefore closes every received descriptor.
    class Incoming {
    public:
      bool receive(int channel);

      [[nodiscard]] Kind kind() const;

      void validateMonitor() const;

      Connection take();

    private:
      ds::Array<Byte, Protocol::frame_bytes> bytes_{};
      ds::Array<FileDescriptor, Protocol::descriptor_count> sockets_;
      std::size_t size_ = 0;
      std::size_t received_ = 0;
    };

  }
}

// Interface: redirect/ingress.cppm
export {
  namespace telar::runtime::redirect {

    struct PrivilegedPeer {
      static bool allows(uid_t uid) noexcept;
    };

    // Generic over the caller's sink and peer policy.
    template <typename Sink, typename PeerPolicy = PrivilegedPeer>
    class TBC_GENERIC Ingress {
      struct Peer {
        FileDescriptor socket;
        Incoming incoming;
        std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
        bool monitor = false;
      };

    public:
      inline explicit Ingress(std::string_view path, Sink& sink)
          : listener_(path),
            sink_(sink),
            worker_([this] {
              run();
            }) {}

      inline ~Ingress() {
        stopping_.store(true, std::memory_order_release);
        wake_.notify();
        worker_.join();
      }

      Ingress(const Ingress&) = delete;
      Ingress& operator=(const Ingress&) = delete;
      Ingress(Ingress&&) = delete;
      Ingress& operator=(Ingress&&) = delete;

      inline MonitorState status() const noexcept {
        return status_.load(std::memory_order_acquire);
      }

      inline void stop() noexcept {
        stop_requested_.store(true, std::memory_order_release);
        wake_.notify();
      }

    private:
      inline void run() noexcept {
        while (!stopping_.load(std::memory_order_acquire)) {
          try {
            step();
          } catch (const std::exception& error) {
            writeErrorLine("telar redirect ingress: {}", error.what());
          }
        }
      }

      inline void step() {
        ds::Array<pollfd, maximum_peers + 2> descriptors{};

        descriptors.atMut(0) = {.fd = listener_.descriptor(), .events = POLLIN, .revents = 0};
        descriptors.atMut(1) = {.fd = wake_.descriptor(), .events = POLLIN, .revents = 0};
        for (std::size_t index = 0; index < peers_.size(); ++index) {
          descriptors.atMut(index + 2) = {.fd = peers_[index] ? peers_[index]->socket.get() : -1, .events = POLLIN, .revents = 0};
        }

        constexpr int poll_ms = 100;
        if (::poll(descriptors.dataMut(), descriptors.size(), poll_ms) < 0 && sys::lastError() != EINTR) {
          throw SystemError{"Poll redirected socket ingress"};
        }

        if (stopping_.load(std::memory_order_acquire)) {
          return;
        }

        if (anyFlag(descriptors[1].revents, POLLIN)) {
          wake_.drain();
        }

        if (stop_requested_.exchange(false, std::memory_order_acq_rel)) {
          forwardStop();
        }

        if (anyFlag(descriptors[0].revents, POLLIN)) {
          accept();
        }

        for (std::size_t index = 0; index < peers_.size(); ++index) {
          if (peers_[index]) {
            serve(index, descriptors[index + 2]);
          }
        }
      }

      // Asks the monitor to stop; one that cannot be asked leaves its rules for cleanup.
      inline void forwardStop() {
        for (auto& peer : peers_.viewMut()) {
          if (peer && peer->monitor) {
            status_.store(MonitorState::stopping, std::memory_order_release);
            if (::send(peer->socket.get(), &stop_request, 1, 0) != 1) {
              status_.store(MonitorState::cleanup_required, std::memory_order_release);
              peer.reset();
            }
          }
        }
      }

      // Serves the peer at `index` on what poll reported for it, and drops it once it is done,
      // failed or late.
      inline void serve(std::size_t index, const pollfd& polled) {
        const auto readiness = polled.revents;
        bool close = anyFlag(readiness, POLLERR, POLLNVAL);

        try {
          if (const auto done = attend(index, polled)) {
            close = *done;
          }
        } catch (const std::exception&) {
          close = true;
        }

        // admitMonitor may have changed the peers, so the peer is looked up again.
        auto& peer = peers_.atMut(index);

        if (close || (!peer->monitor && std::chrono::steady_clock::now() >= peer->deadline)) {
          if (peer->monitor) {
            status_.store(MonitorState::cleanup_required, std::memory_order_release);
          }

          peer.reset();
        }
      }

      // Reads what the peer at `index` sent and acts on it: whether the peer is done, or none when it
      // had nothing to act on.
      inline ds::Option<bool> attend(std::size_t index, const pollfd& polled) {
        const auto readiness = polled.revents;
        auto& peer = peers_.atMut(index);

        if (!peer->monitor && anyFlag(readiness, POLLIN, POLLHUP) && peer.getMut().incoming.receive(peer->socket.get())) {
          if (peer->incoming.kind() == Kind::monitor) {
            return admitMonitor(index);
          }

          return handOff(peer.getMut(), sink_);
        }

        if (peer->monitor && anyFlag(readiness, POLLIN, POLLHUP)) {
          return advanceMonitor(peer.getMut(), status_);
        }

        return ds::none;
      }

      // Makes the peer at `index`, whose frame asked to monitor, the endpoint's one monitor and
      // answers with this process's account; whether the peer is done.
      inline bool admitMonitor(std::size_t index) {
        peers_[index]->incoming.validateMonitor();
        if (std::ranges::any_of(peers_, [](const auto& candidate) {
              return candidate && candidate->monitor;
            })) {
          throw EncodingError{"A redirect helper already owns this endpoint"};
        }

        auto& peer = peers_.atMut(index).getMut();

        peer.monitor = true;
        status_.store(MonitorState::starting, std::memory_order_release);
        ds::Array<Byte, sizeof(std::uint32_t)> reply{};
        plugins::FrameWriter writer{reply.viewMut()};

        writer.integer(static_cast<std::uint32_t>(::geteuid()));
        return ::send(peer.socket.get(), reply.data(), reply.size(), 0) != static_cast<ssize_t>(reply.size());
      }

      // Hands the redirected connection the peer sent to the sink and tells the peer whether it was
      // admitted; the peer is done either way.
      inline static bool handOff(Peer& peer, Sink& sink) {
        auto connection = peer.incoming.take();

        connection.lifetime.reset(::fcntl(peer.socket.get(), F_DUPFD_CLOEXEC, 0));
        if (!connection.lifetime) {
          throw SystemError{"Keep redirected connection lifetime"};
        }

        const Byte admitted = sink.adopt(std::move(connection)) ? 1 : 0;

        ::send(peer.socket.get(), &admitted, sizeof(admitted), 0);
        return true;
      }

      inline static bool advanceMonitor(Peer& peer, std::atomic<MonitorState>& status) {
        for (std::size_t count = 0; count < 3; ++count) {
          Byte update = 0;
          const auto received = ::recv(peer.socket.get(), &update, 1, 0);
          if (received < 0 && socketWouldBlock(sys::lastError())) {
            return false;
          }

          if (received != 1) {
            return true;
          }

          if (update == static_cast<Byte>(MonitorUpdate::active) && (status.load(std::memory_order_acquire) == MonitorState::starting || status.load(std::memory_order_acquire) == MonitorState::stopping)) {
            if (status.load(std::memory_order_acquire) == MonitorState::starting) {
              status.store(MonitorState::active, std::memory_order_release);
            }
          } else if (update == static_cast<Byte>(MonitorUpdate::stopped)) {
            status.store(MonitorState::idle, std::memory_order_release);
            peer.monitor = false;
            return true;
          } else {
            return true;
          }
        }

        return true;
      }

      inline void accept() {
        auto socket = listener_.accept(LocalPeerPolicy::same_user_or_root);
        if (!socket) {
          return;
        }

        const auto credentials = peerCredentials(socket.get());
        if (!credentials || !PeerPolicy::allows(credentials->user)) {
          return;
        }

        for (auto& peer : peers_.viewMut()) {
          if (!peer) {
            peer.emplace();
            peer.getMut().socket = std::move(socket);
            return;
          }
        }
      }

      static constexpr std::size_t maximum_peers = 32;
      LocalListener listener_;
      Sink& sink_;
      CompletionSignal wake_;
      ds::Array<ds::Option<Peer>, maximum_peers> peers_;
      std::atomic<bool> stopping_{false};
      std::atomic<bool> stop_requested_{false};
      std::atomic<MonitorState> status_{MonitorState::idle};
      std::thread worker_;
    };

  }
}

// Interface: redirect/selection.cppm
export {
  namespace telar::runtime::redirect {

    // Generic over the caller's resolver.
    template <HostnameResolver Resolver = SystemNameResolver>
    class TBC_GENERIC Selection {
      using Resolutions = NameResolutions<Resolver>;
      using Clock = std::chrono::steady_clock;

      struct Pending {
        ds::Option<typename Resolutions::Ticket> ticket;
        std::uint16_t port = 0;
      };

    public:
      static constexpr std::size_t maximum_argument_bytes = INET6_ADDRSTRLEN + 8;

      inline explicit Selection(std::span<const std::string_view> input, const std::atomic<bool>& cancelled, Clock::time_point deadline) {
        if (input.empty() || input.size() > Target::maximum_targets) {
          throw std::invalid_argument{"Redirect requires 1..16 destinations"};
        }

        ds::Array<Pending, Target::maximum_targets> pending;
        ds::Array<ds::Option<Target>, Target::maximum_targets> numeric_targets;
        CompletionSignal signal;
        typename Resolutions::Notifications notifications{signal};
        std::size_t remaining = 0;

        for (std::size_t index = 0; index < input.size(); ++index) {
          check(cancelled, deadline);
          const auto authority = Target::authority(input[index]);
          if (numeric(input[index], authority.hostname)) {
            const auto target = Target::parse(input[index]);
            if (std::ranges::any_of(std::span{numeric_targets}.first(index), [&](const auto& other) {
                  return other && other->host.view() == target.host.view() && other->port == target.port;
                })) {
              throw std::invalid_argument{"Duplicate redirect destination"};
            }

            numeric_targets.atMut(index) = target;
            append(target);
            continue;
          }

          request(pending.atMut(index), authority);
          ++remaining;
        }

        while (remaining != 0) {
          check(cancelled, deadline);
          for (auto& item : pending.viewMut()) {
            if (item.ticket && collect(item)) {
              --remaining;
            }
          }

          if (remaining != 0) {
            waitForAnswers(signal);
          }
        }
      }

      [[nodiscard]] inline std::span<const Target> targets() const noexcept {
        return std::span{targets_}.first(count_);
      }

      [[nodiscard]] inline std::string_view argument(std::size_t index) const noexcept {
        return arguments_[index].view();
      }

    private:
      inline static void check(const std::atomic<bool>& cancelled, Clock::time_point deadline) {
        if (cancelled) {
          throw RequestError{FailureCode::invalid_request, "Redirect selection cancelled"};
        }

        if (Clock::now() >= deadline) {
          throw RequestError{FailureCode::resource_limit, "Redirect hostname resolution deadline exceeded"};
        }
      }

      // Whether a destination names a numeric address, which needs no resolver.
      inline static bool numeric(std::string_view text, std::string_view host) noexcept {
        return text.starts_with('[') || host.contains(':') || std::ranges::all_of(host, [](char byte) {
          return (byte >= '0' && byte <= '9') || byte == '.';
        });
      }

      inline static void request(Pending& item, const ProxyTarget& authority) {
        item.port = authority.port;
        item.ticket = Resolutions::request(authority.hostname);
        if (!item.ticket) {
          throw SystemError{"Redirect hostname resolver is at capacity", EAGAIN};
        }
      }

      // Whether the resolver has answered `item`, whose addresses are then appended.
      inline bool collect(Pending& item) {
        typename Resolutions::Result result;
        if (!item.ticket->collect(result)) {
          return false;
        }

        if (result.summary.error != 0 || result.summary.found == 0) {
          throw std::invalid_argument{"Redirect hostname resolution failed"};
        }

        if (result.summary.found > result.addresses.size()) {
          throw std::invalid_argument{"Redirect hostname has too many addresses"};
        }

        for (const auto& address : std::span{result.addresses}.first(result.summary.found)) {
          append(address, item.port);
        }

        item.ticket.reset();
        return true;
      }

      inline static void waitForAnswers(CompletionSignal& signal) {
        constexpr int poll_ms = 20;
        pollfd descriptor{.fd = signal.descriptor(), .events = POLLIN, .revents = 0};
        if (::poll(&descriptor, 1, poll_ms) < 0 && sys::lastError() != EINTR) {
          throw SystemError{"Wait for redirect hostname resolution"};
        }

        signal.drain();
      }

      inline void append(const NetworkAddress& address, std::uint16_t port) {
        const auto family = address.storage.ss_family;
        ds::Array<char, INET6_ADDRSTRLEN> host{};

        if (family == AF_INET) {
          const auto ipv4 = addressAs<sockaddr_in>(address.storage);
          if (address.length != sizeof(sockaddr_in) || (::inet_ntop(AF_INET, &ipv4.sin_addr, host.dataMut(), host.size()) == nullptr)) {
            throw std::invalid_argument{"Invalid resolved IPv4 destination"};
          }
        } else if (family == AF_INET6) {
          const auto ipv6 = addressAs<sockaddr_in6>(address.storage);
          if (address.length != sizeof(sockaddr_in6) || ipv6.sin6_scope_id != 0 || (::inet_ntop(AF_INET6, &ipv6.sin6_addr, host.dataMut(), host.size()) == nullptr)) {
            throw std::invalid_argument{"Invalid resolved IPv6 destination"};
          }
        } else {
          throw std::invalid_argument{"Resolved destination must use IP"};
        }

        ds::Array<char, maximum_argument_bytes> text{};

        append(Target::parse(formatAuthority(text.viewMut(), std::string_view{host.data()}, port)));
      }

      inline void append(const Target& target) {
        if (std::ranges::any_of(targets(), [&](const auto& other) {
              return other.host.view() == target.host.view() && other.port == target.port;
            })) {
          return;
        }

        if (count_ == targets_.size()) {
          throw std::invalid_argument{"Resolved redirect selection exceeds 16 destinations"};
        }

        ds::Array<char, maximum_argument_bytes> argument{};
        const auto text = formatAuthority(argument.viewMut(), target.host.view(), target.port);

        targets_.atMut(count_) = target;
        arguments_.atMut(count_++).assign(text);
      }

      ds::Array<Target, Target::maximum_targets> targets_;
      ds::Array<FixedText<maximum_argument_bytes>, Target::maximum_targets> arguments_;
      std::size_t count_ = 0;
    };

  }
}
