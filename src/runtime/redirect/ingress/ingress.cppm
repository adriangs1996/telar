module;
#include "tbc/hot_path.hpp"
#include <cstdlib>
#include <new>

#include <arpa/inet.h>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <netinet/in.h>
#include <sys/socket.h>

#if (defined(__APPLE__))
#include <cerrno>
#endif
#if (defined(__APPLE__))
#include <net/if.h>
#endif
#if (defined(__APPLE__))
#include <net/if_utun.h>
#endif
#if (defined(__APPLE__))
#include <netinet6/in6_var.h>
#endif
#if (defined(__APPLE__))
#include <sys/ioctl.h>
#endif
#if (defined(__APPLE__))
#include <sys/kern_control.h>
#endif
#if (defined(__APPLE__))
#include <sys/sys_domain.h>
#endif
#if (!(defined(__APPLE__)))
#include <fcntl.h>
#endif
#if (!(defined(__APPLE__)))
#include <linux/if_ether.h>
#endif
#if (!(defined(__APPLE__)))
#include <linux/if_tun.h>
#endif
#if (!(defined(__APPLE__)))
#include <net/if.h>
#endif
#if (!(defined(__APPLE__)))
#include <sys/ioctl.h>
#endif
#if (!(defined(__APPLE__)))
#include <sys/uio.h>
#endif
#include <pcap/pcap.h>
#include <sys/ioctl.h>

#include <cerrno>
#include <csignal>
#include <netinet/tcp.h>
#include <sys/uio.h>

#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdio>
#include <netdb.h>
#include <pthread.h>

export module telar.runtime.redirect.ingress;

import std;
import telar.sys.posix;
import telar.tbc;

export import telar.runtime.platform.name_resolutions;

export import telar.runtime.platform.private_tunnel;

export import telar.platform.net;
export import telar.runtime.platform.local_listener;

import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.client;
import telar.platform.error;
import telar.runtime.platform.request_worker;
import telar.runtime.vocabulary.frames;
import telar.base.text;

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
      FileDescriptor lifetime{};
    };

  }
}

// Interface: redirect/discovery.cppm
export {
  namespace telar::runtime::redirect {

    class Discovery {
    public:
      Discovery();

      int descriptor() const noexcept;

      std::string_view name() const noexcept;

      tbc::view<std::span<Byte>, tbc::lt::a> receive(tbc::view<std::span<Byte>, tbc::lt::a> bytes);

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

      static tbc::view<std::span<const Byte>, tbc::lt::a> encode(tbc::view<std::span<Byte>, tbc::lt::a> output, Kind kind, const Target& target);

      static void send(int channel, const Connection& connection);
    };

    // Descriptors are adopted immediately, including on malformed/truncated frames.
    // A failed decode therefore closes every received descriptor.
    class Incoming {
    public:
      bool receive(int channel);

      Kind kind() const;

      void validateMonitor() const;

      Connection take();

    private:
      std::array<Byte, Protocol::frame_bytes> bytes_{};
      std::array<FileDescriptor, Protocol::descriptor_count> sockets_;
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
    class TBC_HOT_PATH Ingress {
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
            std::fprintf(stderr, "telar redirect ingress: %s\n", error.what());
          }
        }
      }

      inline void step() {
        std::array<pollfd, maximum_peers + 2> descriptors{};

        descriptors[0] = {.fd = listener_.descriptor(), .events = POLLIN, .revents = 0};
        descriptors[1] = {.fd = wake_.descriptor(), .events = POLLIN, .revents = 0};
        for (std::size_t index = 0; index < peers_.size(); ++index) {
          descriptors[index + 2] = {.fd = peers_[index] ? peers_[index]->socket.get() : -1, .events = POLLIN, .revents = 0};
        }

        constexpr int poll_ms = 100;
        if (::poll(descriptors.data(), descriptors.size(), poll_ms) < 0 && sys::lastError() != EINTR) {
          throw SystemError{"Poll redirected socket ingress"};
        }

        if (stopping_.load(std::memory_order_acquire)) {
          return;
        }

        if (descriptors[1].revents & POLLIN) {
          wake_.drain();
        }

        if (stop_requested_.exchange(false, std::memory_order_acq_rel)) {
          for (auto& peer : peers_) {
            if (peer && peer->monitor) {
              status_.store(MonitorState::stopping, std::memory_order_release);
              if (::send(peer->socket.get(), &stop_request, 1, 0) != 1) {
                status_.store(MonitorState::cleanup_required, std::memory_order_release);
                peer.reset();
              }
            }
          }
        }

        if (descriptors[0].revents & POLLIN) {
          accept();
        }

        for (std::size_t index = 0; index < peers_.size(); ++index) {
          auto& peer = peers_[index];
          if (!peer) {
            continue;
          }

          const auto readiness = descriptors[index + 2].revents;
          bool close = readiness & (POLLERR | POLLNVAL);

          try {
            if (!peer->monitor && (readiness & (POLLIN | POLLHUP)) && peer->incoming.receive(peer->socket.get())) {
              if (peer->incoming.kind() == Kind::monitor) {
                peer->incoming.validateMonitor();
                if (std::ranges::any_of(peers_, [](const auto& candidate) {
                      return candidate && candidate->monitor;
                    })) {
                  throw EncodingError{"A redirect helper already owns this endpoint"};
                }

                peer->monitor = true;
                status_.store(MonitorState::starting, std::memory_order_release);
                std::array<Byte, sizeof(std::uint32_t)> reply;
                plugins::FrameWriter writer{reply};

                writer.integer(static_cast<std::uint32_t>(::geteuid()));
                close = ::send(peer->socket.get(), reply.data(), reply.size(), 0) != static_cast<ssize_t>(reply.size());
              } else {
                auto connection = peer->incoming.take();

                connection.lifetime.reset(::fcntl(peer->socket.get(), F_DUPFD_CLOEXEC, 0));
                if (!connection.lifetime) {
                  throw SystemError{"Keep redirected connection lifetime"};
                }

                const Byte admitted = sink_.adopt(std::move(connection)) ? 1 : 0;

                ::send(peer->socket.get(), &admitted, sizeof(admitted), 0);
                close = true;
              }
            } else if (peer->monitor && (readiness & (POLLIN | POLLHUP))) {
              close = advanceMonitor(*peer, status_);
            }
          } catch (const std::exception&) {
            close = true;
          }

          if (close || (!peer->monitor && std::chrono::steady_clock::now() >= peer->deadline)) {
            if (peer->monitor) {
              status_.store(MonitorState::cleanup_required, std::memory_order_release);
            }

            peer.reset();
          }
        }
      }

      inline static bool advanceMonitor(Peer& peer, std::atomic<MonitorState>& status) {
        for (std::size_t count = 0; count < 3; ++count) {
          Byte update;
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

        for (auto& peer : peers_) {
          if (!peer) {
            peer.emplace();
            peer->socket = std::move(socket);
            return;
          }
        }
      }

      static constexpr std::size_t maximum_peers = 32;
      LocalListener listener_;
      Sink& sink_;
      CompletionSignal wake_;
      std::array<std::optional<Peer>, maximum_peers> peers_;
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
    class TBC_HOT_PATH Selection {
      using Resolutions = NameResolutions<Resolver>;
      using Clock = std::chrono::steady_clock;

      struct Pending {
        std::optional<typename Resolutions::Ticket> ticket;
        std::uint16_t port = 0;
      };

    public:
      static constexpr std::size_t maximum_argument_bytes = INET6_ADDRSTRLEN + 8;

      inline explicit Selection(std::span<const std::string_view> input, const std::atomic<bool>& cancelled, Clock::time_point deadline) {
        if (input.empty() || input.size() > Target::maximum_targets) {
          throw std::invalid_argument{"Redirect requires 1..16 destinations"};
        }

        std::array<Pending, Target::maximum_targets> pending;
        std::array<std::optional<Target>, Target::maximum_targets> numeric_targets;
        CompletionSignal signal;
        typename Resolutions::Notifications notifications{signal};
        std::size_t remaining = 0;

        for (std::size_t index = 0; index < input.size(); ++index) {
          check(cancelled, deadline);
          const auto authority = Target::authority(input[index]);
          const auto host = authority.hostname;
          const bool numeric = input[index].starts_with('[') || host.contains(':') || std::ranges::all_of(host, [](char byte) {
            return (byte >= '0' && byte <= '9') || byte == '.';
          });
          if (numeric) {
            const auto target = Target::parse(input[index]);
            if (std::ranges::any_of(std::span{numeric_targets}.first(index), [&](const auto& other) {
                  return other && other->host.view() == target.host.view() && other->port == target.port;
                })) {
              throw std::invalid_argument{"Duplicate redirect destination"};
            }

            numeric_targets[index] = target;
            append(target);
            continue;
          }

          pending[index].port = authority.port;
          pending[index].ticket = Resolutions::request(host);
          if (!pending[index].ticket) {
            throw SystemError{"Redirect hostname resolver is at capacity", EAGAIN};
          }

          ++remaining;
        }

        while (remaining != 0) {
          check(cancelled, deadline);
          for (auto& item : pending) {
            if (!item.ticket) {
              continue;
            }

            typename Resolutions::Result result;
            if (!item.ticket->collect(result)) {
              continue;
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
            --remaining;
          }

          if (remaining != 0) {
            pollfd descriptor{signal.descriptor(), POLLIN, 0};
            if (::poll(&descriptor, 1, 20) < 0 && sys::lastError() != EINTR) {
              throw SystemError{"Wait for redirect hostname resolution"};
            }

            signal.drain();
          }
        }
      }

      inline std::span<const Target> targets() const noexcept {
        return std::span{targets_}.first(count_);
      }

      inline std::string_view argument(std::size_t index) const noexcept {
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

      inline void append(const NetworkAddress& address, std::uint16_t port) {
        const auto family = address.storage.ss_family;
        std::array<char, INET6_ADDRSTRLEN> host{};

        if (family == AF_INET) {
          if (address.length != sizeof(sockaddr_in) || !::inet_ntop(AF_INET, &reinterpret_cast<const sockaddr_in*>(&address.storage)->sin_addr, host.data(), host.size())) {
            throw std::invalid_argument{"Invalid resolved IPv4 destination"};
          }
        } else if (family == AF_INET6) {
          const auto& v6 = *reinterpret_cast<const sockaddr_in6*>(&address.storage);
          if (address.length != sizeof(sockaddr_in6) || v6.sin6_scope_id != 0 || !::inet_ntop(AF_INET6, &v6.sin6_addr, host.data(), host.size())) {
            throw std::invalid_argument{"Invalid resolved IPv6 destination"};
          }
        } else {
          throw std::invalid_argument{"Resolved destination must use IP"};
        }

        std::array<char, maximum_argument_bytes> text{};

        std::snprintf(text.data(), text.size(), family == AF_INET6 ? "[%s]:%u" : "%s:%u", host.data(), static_cast<unsigned>(port));
        append(Target::parse(text.data()));
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

        std::array<char, maximum_argument_bytes> argument{};
        const auto host = target.host.view();

        std::snprintf(argument.data(), argument.size(), target.endpoint.storage.ss_family == AF_INET6 ? "[%.*s]:%u" : "%.*s:%u", static_cast<int>(host.size()), host.data(), static_cast<unsigned>(target.port));
        targets_[count_] = target;
        arguments_[count_++].assign(argument.data());
      }

      std::array<Target, Target::maximum_targets> targets_;
      std::array<FixedText<maximum_argument_bytes>, Target::maximum_targets> arguments_;
      std::size_t count_ = 0;
    };

  }
}
