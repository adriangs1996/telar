module;
#include "tbc/annotations.hpp"

export module telar.runtime.redirect.socket_owners;

import std;
import telar.sys.socket;
import telar.sys.process;
import telar.sys.posix;

import telar.runtime.redirect.pf_rules;
import telar.runtime.redirect.ingress;
import telar.platform.process;

import telar.runtime.platform.process_probe;
import telar.base.memory.containers;
import telar.base.text;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.vocabulary;
import telar.runtime.redirect.direction;
import telar.base.ds;

#if defined(__APPLE__)

import telar.base.memory.allocators;
import telar.base.memory.sensitive;

#endif

#if (!(defined(__APPLE__)))
#endif

#if defined(__APPLE__)

import telar.runtime.redirect.record;
import telar.runtime.vocabulary.traffic;
import telar.sys.apple;

#endif

// Interface: redirect/local_addresses.cppm
export {
  namespace telar::runtime::redirect {

    class LocalAddresses {
    public:
      LocalAddresses();

      bool contains(const Target& target) const noexcept;

      static ds::Array<bool, Target::maximum_targets> selection(std::span<const Target> targets, Direction direction);

    private:
      std::unique_ptr<ifaddrs, decltype(&freeifaddrs)> addresses_;
    };

  }
}

// pfctl and the sessions that drive it exist on macOS only.
#if defined(__APPLE__)

// Interface: redirect/pf_command.cppm
export {
  namespace telar::runtime::redirect {

    class PfCommand {
    public:
      explicit PfCommand(Memory& memory) noexcept;

      ds::String<Memory> run(std::span<const std::string_view> arguments, std::string_view input = {});

    private:
      Memory& memory_;
    };

  }
}

// Interface: redirect/pf_session.cppm
export {
  namespace telar::runtime::redirect {

    // Generic over the caller's command, state and loopback.
    template <typename Command, typename State, typename Loopback, Allocator Memory>
    class TBC_GENERIC PfSession {
    public:
      inline explicit PfSession(Command& command, State& state, const PfIdentity<Memory>& identity, Loopback& loopback) noexcept
          : command_(command),
            state_(state),
            identity_(identity),
            loopback_(loopback) {}

      inline ~PfSession() {
        try {
          stop();
        } catch (const std::exception& error) {
          std::fprintf(stderr, "telar redirect cleanup: %s; retry traffic redirect-cleanup\n", error.what());
        }
      }

      PfSession(const PfSession&) = delete;
      PfSession& operator=(const PfSession&) = delete;

      inline void recover() {
        token_ = state_.load();
        stop();
      }

      inline void start(std::string_view rules) {
        recover();
        const auto filters = run({"-sr"});
        const auto translations = run({"-sn"});
        if (!std::string_view{filters}.contains("anchor \"com.apple/*\"") || !std::string_view{translations}.contains("rdr-anchor \"com.apple/*\"")) {
          throw std::runtime_error{"PF must expose com.apple/* filter and rdr anchors; system rules were not changed"};
        }

        run({"-n", "-a", identity_.anchor, "-f", "-"}, rules);
        token_ = parseToken(run({"-E"}));
        state_.save(*token_);
        run({"-a", identity_.anchor, "-f", "-"}, rules);
        loopback_.acquire();
      }

      inline void stop() {
        if (!token_) {
          return;
        }

        // macOS only supports host/network state kills. Leave existing states to
        // expire rather than killing unrelated connections with a broader match.
        std::exception_ptr failure;

        for (const auto kind : {"rules", "nat"}) {
          try {
            run({"-a", identity_.anchor, "-F", kind});
          } catch (...) {
            if (!failure) {
              failure = std::current_exception();
            }
          }
        }

        if (failure) {
          // Keep the enable reference and recovery record until both rule sets
          // have been removed, including when another service already enabled PF.
          std::rethrow_exception(failure);
        }

        loopback_.release();
        ds::Array<char, 32> value{};
        const auto result = std::to_chars(value.dataMut(), value.dataMut() + value.size(), *token_);

        if (*token_ != 0) {
          run({"-X", std::string_view{value.data(), static_cast<std::size_t>(result.ptr - value.data())}});
          token_ = 0;
          state_.save(0);
        }

        state_.clear();
        token_.reset();
      }

      inline static std::uint64_t parseToken(std::string_view output) {
        while (!output.empty()) {
          const auto newline = output.find('\n');
          auto line = output.substr(0, newline);
          if (line.starts_with("Token")) {
            const auto colon = line.find(':');
            if (colon != std::string_view::npos) {
              const auto token = parseExact<std::uint64_t>(trimText(line.substr(colon + 1), " \t\r")).valueOr(0);
              if (token != 0) {
                return token;
              }
            }
          }

          if (newline == std::string_view::npos) {
            break;
          }

          output.remove_prefix(newline + 1);
        }

        throw std::runtime_error{"PF did not return an enable-reference token"};
      }

      inline void replace(std::string_view rules) {
        if (!token_) {
          throw std::runtime_error{"Redirect session is not enabled"};
        }

        run({"-a", identity_.anchor, "-f", "-"}, rules);
      }

    private:
      inline auto run(std::initializer_list<std::string_view> arguments, std::string_view input = {}) {
        return command_.run(std::span{arguments.begin(), arguments.size()}, input);
      }

      Command& command_;
      State& state_;
      const PfIdentity<Memory>& identity_;
      Loopback& loopback_;
      ds::Option<std::uint64_t> token_;
    };

  }
}

#endif

// Interface: redirect/process_token.cppm
export {
  namespace telar::runtime::redirect {

    class ProcessToken {
    public:
      static constexpr std::size_t maximum_bytes = 64;

      static ProcessIdentity parse(std::string_view value);

      static FixedText<maximum_bytes> format(const ProcessIdentity& process);

    private:
      static std::uint64_t number(std::string_view value);
    };

  }
}

#if defined(__APPLE__)
// Interface: redirect/socket_accounts.cppm
export {
  namespace telar::runtime::redirect {

    class SocketAccounts {
    public:
      explicit SocketAccounts(Memory& memory) noexcept;

      void validate();

      ds::Option<uid_t> peer(int descriptor);

      static ds::Option<uid_t> decode(std::span<const Byte> bytes, const sockaddr_storage& local, const sockaddr_storage& peer);

    private:
      void refresh();

      static bool matches(const xinpcb64& pcb, const sockaddr_storage& local, const sockaddr_storage& peer) noexcept;

      static constexpr std::size_t maximum_bytes = 4 * 1024 * 1024;
      Memory& memory_;
      ds::Option<SensitiveAllocation<Memory>> snapshot_;
      std::size_t size_ = 0;
    };

  }
}

#endif

#if defined(__linux__)
// Interface: redirect/linux/tcp_table.cppm
export {
  namespace telar::runtime::redirect {

    struct LinuxTcpSocket {
      sockaddr_storage local{};
      sockaddr_storage remote{};
      uid_t user = 0;
      std::uint64_t inode = 0;
      unsigned state = 0;

      bool matches(const Target& source, const Target& destination) const noexcept;

      static ds::Option<LinuxTcpSocket> parse(std::string_view line, int family) noexcept;

    private:
      template <typename Integer>
      static bool number(std::string_view input, Integer& output, int base) noexcept;

      static bool endpoint(std::string_view input, int family, sockaddr_storage& output) noexcept;

      static bool endpointMatches(const sockaddr_storage& left, const sockaddr_storage& right) noexcept;
    };

    // Generic over the caller's visitor.
    template <typename Visitor>
    TBC_GENERIC void visitLinuxTcpSockets(Visitor&& visit) {
      constexpr ds::Array families{AF_INET, AF_INET6};
      constexpr std::size_t read_capacity = 4096;
      constexpr std::size_t maximum_line_bytes = 1024;
      constexpr std::size_t maximum_entries = 65536;
      for (const auto family : families) {
        FileDescriptor file{::open(family == AF_INET ? "/proc/net/tcp" : "/proc/net/tcp6", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)};
        if (!file) {
          if (family == AF_INET6 && sys::lastError() == ENOENT) {
            continue;
          }
          throw SystemError{"Open TCP socket table"};
        }

        ds::Array<char, read_capacity> buffer;
        ds::Array<char, maximum_line_bytes> line;
        std::size_t length = 0;
        std::size_t entries = 0;
        bool header = true;
        for (;;) {
          const auto count = ::read(file.get(), buffer.dataMut(), buffer.size());
          if (count < 0 && sys::lastError() == EINTR) {
            continue;
          }
          if (count < 0) {
            throw SystemError{"Read TCP socket table"};
          }
          if (count == 0) {
            if (length != 0) {
              throw SystemError{"Truncated TCP socket table", EINVAL};
            }
            break;
          }

          for (const auto byte : std::span{buffer}.first(static_cast<std::size_t>(count))) {
            if (byte != '\n') {
              if (length == line.size()) {
                throw SystemError{"TCP socket record exceeds its limit", EOVERFLOW};
              }
              line.atMut(length++) = byte;
              continue;
            }
            if (header) {
              header = false;
            } else {
              if (++entries > maximum_entries) {
                throw SystemError{"TCP socket table exceeds its limit", EOVERFLOW};
              }
              const auto socket = LinuxTcpSocket::parse({line.data(), length}, family);
              if (!socket) {
                throw SystemError{"Invalid TCP socket record", EINVAL};
              }
              if (!visit(*socket)) {
                return;
              }
            }
            length = 0;
          }
        }
      }
    }

  }
}

#endif

// Interface: redirect/socket_owners.cppm
export {
  namespace telar::runtime::redirect {

    class SocketOwners {
    public:
      static constexpr std::size_t maximum_processes = 16;
      static constexpr std::size_t maximum_descriptors = 4096;

      struct Result {
        ds::Option<ProcessIdentity> process;
        bool complete = true;
      };

      explicit SocketOwners(uid_t uid, std::span<const ProcessIdentity> selected);

      bool enabled() const noexcept;

      std::span<const ProcessIdentity> processes() const noexcept;

      Result find(const FlowKey& flow) noexcept;

    private:
      ProcessInspector inspector_;
      ds::Array<ProcessIdentity, maximum_processes> processes_;
      std::size_t count_ = 0;
#if defined(__APPLE__)
      ds::Array<proc_fdinfo, maximum_descriptors> descriptors_;
#endif
    };

  }

#if defined(__APPLE__)
  namespace telar::runtime::redirect {

    bool matchesMacosSocket(const in_sockinfo& socket, const FlowKey& flow) noexcept;

  }
#endif
}

#if defined(__APPLE__)
// Interface: redirect/helper.cppm
export {
  namespace telar::runtime::redirect {

    class Listener {
    public:
      explicit Listener(const Target& target, bool incoming = false);

      int descriptor() const noexcept;

      Mapping mapping() const noexcept;

      FileDescriptor accept() const;

    private:
      Target target_;
      FileDescriptor socket_;
      std::uint16_t port_ = 0;
      bool incoming_ = false;
    };

    class ShutdownSignals {
    public:
      ShutdownSignals();

      ~ShutdownSignals();

      bool stopping() const noexcept;

    private:
      sigset_t selected_{};
      sigset_t previous_{};
    };

    class Helper {
      struct Pending {
        Connection connection;
        std::chrono::steady_clock::time_point deadline;
        std::size_t flow;
      };

      struct Flow {
        FlowKey key;
        FileDescriptor lifetime{};
        std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
        bool accepted = false;
        bool incoming = false;
        ds::Option<RoutePath> bypass;
      };

    public:
      explicit Helper(Memory& memory, std::string_view endpoint, std::span<const Target> targets, std::span<const ProcessIdentity> processes = {}, Direction direction = Direction::outbound);

      ds::String<Memory> plan(uid_t uid, const PfIdentity<Memory>& identity, bool dry_run = false);

      void run(const PfIdentity<Memory>& identity);

    private:
      // Generic over the caller's session.
      template <typename Session>
      TBC_GENERIC void discover(Session& session, uid_t uid, const PfIdentity<Memory>& identity) {
        ds::Array<Byte, 65540> bytes;
        auto packet = discovery_.getMut().receive(bytes.viewMut());
        if (packet.empty()) {
          return;
        }

        if (owners_ || allowsIncoming(direction_)) {
          return;
        }

        discovered(session, uid, identity, packet);
      }

      template <typename Session>
      TBC_GENERIC void discovered(Session& session, uid_t uid, const PfIdentity<Memory>& identity, std::span<Byte> packet, const PacketLog::Metadata* metadata = nullptr) {
        const auto key = FlowKey::syn(packet);
        const bool incoming = metadata && metadata->incoming;
        if (!key || (incoming ? !allowsIncoming(direction_) : !allowsOutgoing(direction_)) || !std::ranges::any_of(std::span{mappings_}.first(count_), [&](const auto& mapping) {
              return (!incoming || mapping.incoming) && FlowKey::same(mapping.target, key->destination);
            })) {
          std::fprintf(stderr, "telar redirect: rejected unsupported discovery packet\n");
          return;
        }

        if (incoming && (metadata->interface_index == 0 || metadata->interface.view() == "lo0" || metadata->interface.view() == discovery_->name() || !LocalAddresses{}.contains(key->destination))) {
          throw SystemError{"Incoming redirect destination/interface is no longer local", EADDRNOTAVAIL};
        }

        const auto found = std::ranges::find_if(flows_, [&](const auto& flow) {
          return flow && flow->incoming == incoming && flow->key.matches(*key);
        });
        if (found == flows_.end()) {
          const auto flows = flows_.viewMut();
          const auto empty = std::ranges::find_if(flows, [](const auto& flow) {
            return !flow;
          });
          if (empty == flows.end()) {
            return;
          }

          Flow flow{.key = *key, .incoming = incoming};

          if (owners_) {
            const auto owner = owners_.getMut().find(*key);
            if (!owner.process) {
              if (!metadata || metadata->interface_index == 0) {
                throw SystemError{"Original process route is unavailable", ENXIO};
              }

              flow.bypass = RoutePath::lookup(key->destination, metadata->interface_index);
              flow.deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
              if (!owner.complete) {
                std::fprintf(stderr, "telar redirect: incomplete process ownership lookup; retaining the direct route\n");
              }
            }
          }

          empty->emplace(std::move(flow));
          session.replace(plan(uid, identity));
          std::fprintf(stderr, "telar redirect: discovered TCP flow for destination port %u\n", key->destination.port);
        }

        discovery_.getMut().inject(packet);
      }

      static void readAll(int socket, std::span<Byte> bytes);

      // The listener is named by its index, as accepting updates the pending and flow tables beside it.
      void accept(std::size_t listener, uid_t uid);

      void handoff(const Connection& connection, std::size_t flow, uid_t uid);

      static constexpr std::size_t maximum_pending = 32;
      static constexpr std::size_t maximum_accept_batch = 16;
      static constexpr std::size_t maximum_flows = 256;
      static constexpr std::size_t pending_offset = 3 + Target::maximum_targets;
      Memory& memory_;
      ds::String<Memory> endpoint_;
      ds::Array<ds::Option<Listener>, Target::maximum_targets> listeners_;
      ds::Array<Mapping, Target::maximum_targets> mappings_;
      ds::Array<ds::Option<Pending>, maximum_pending> pending_;
      ds::Array<ds::Option<Flow>, maximum_flows> flows_;
      ds::Option<Discovery> discovery_;
      ds::Option<NatLookup> nat_;
      ds::Option<PacketLog> packet_log_;
      ds::Option<SocketOwners> owners_;
      ds::Option<SocketAccounts> accounts_;
      ds::Array<ProcessIdentity, SocketOwners::maximum_processes> selected_processes_;
      std::size_t process_count_ = 0;
      std::size_t count_ = 0;
      Direction direction_ = Direction::outbound;
    };

  }
}

#endif
