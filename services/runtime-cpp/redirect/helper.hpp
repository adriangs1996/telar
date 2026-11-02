#include "../platform/peer_credentials.hpp"
#pragma once

#include "../traffic/connection.hpp"
#include "pf_command.hpp"
#include "pf_session.hpp"
#include "protocol.hpp"
#include "record.hpp"
#include "loopback_lease.hpp"
#include "discovery.hpp"
#include "nat_lookup.hpp"
#include "packet_log.hpp"
#include "socket_owners.hpp"
#include "process_token.hpp"
#include "local_addresses.hpp"
#include "socket_accounts.hpp"
#include <csignal>

namespace telar::runtime::redirect {

class Listener {
public:
  explicit Listener(const Target &target, bool incoming = false) : target_(target), socket_(openOriginSocket(target.endpoint.storage.ss_family)), incoming_(incoming) {
    NetworkAddress local = target.endpoint;
    local.setPort(0);
    if (!incoming) {
      if (local.storage.ss_family == AF_INET) { reinterpret_cast<sockaddr_in *>(&local.storage)->sin_addr.s_addr = htonl(INADDR_LOOPBACK); }
      else { reinterpret_cast<sockaddr_in6 *>(&local.storage)->sin6_addr = in6addr_loopback; }
    }
    if (local.storage.ss_family == AF_INET6) {
      const int enabled = 1;
      if (::setsockopt(socket_.get(), IPPROTO_IPV6, IPV6_V6ONLY, &enabled, sizeof(enabled)) != 0) {
        throw SystemError{"Configure IPv6 redirect listener"};
      }
    }
    if (::bind(socket_.get(), local.address(), local.length) != 0 || ::listen(socket_.get(), 128) != 0) {
      throw SystemError{"Bind transparent redirect listener"};
    }
    socklen_t length = local.length;
    if (::getsockname(socket_.get(), reinterpret_cast<sockaddr *>(&local.storage), &length) != 0) {
      throw SystemError{"Read redirect listener port"};
    }
    port_ = ntohs(local.storage.ss_family == AF_INET ? reinterpret_cast<sockaddr_in *>(&local.storage)->sin_port : reinterpret_cast<sockaddr_in6 *>(&local.storage)->sin6_port);
  }

  int descriptor() const noexcept { return socket_.get(); }
  Mapping mapping() const noexcept { return {.target = target_, .listener_port = port_, .incoming = incoming_}; }

  FileDescriptor accept() const {
    FileDescriptor child{::accept(socket_.get(), nullptr, nullptr)};
    if (child) {
      configureProxySocket(child.get());
    } else if (!socketWouldBlock(errno)) {
      throw SystemError{"Accept redirected TCP connection"};
    }
    return child;
  }

private:
  Target target_;
  FileDescriptor socket_;
  std::uint16_t port_ = 0;
  bool incoming_ = false;
};

class ShutdownSignals {
public:
  ShutdownSignals() {
    sigemptyset(&selected_);
    sigaddset(&selected_, SIGINT);
    sigaddset(&selected_, SIGTERM);
    const auto result = ::pthread_sigmask(SIG_BLOCK, &selected_, &previous_);
    if (result != 0) {
      throw SystemError{"Block redirect shutdown signals", result};
    }
  }

  ~ShutdownSignals() {
    // Consume the handled shutdown signal before restoring the old mask.
    sigset_t pending;
    if (::sigpending(&pending) == 0 && (sigismember(&pending, SIGINT) || sigismember(&pending, SIGTERM))) {
      int received;
      ::sigwait(&selected_, &received);
    }
    ::pthread_sigmask(SIG_SETMASK, &previous_, nullptr);
  }

  bool stopping() const noexcept {
    sigset_t pending;
    return ::sigpending(&pending) == 0 && (sigismember(&pending, SIGINT) || sigismember(&pending, SIGTERM));
  }

private:
  sigset_t selected_{};
  sigset_t previous_{};
};

template <Allocator Memory>
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
    std::optional<RoutePath> bypass;
  };

public:
  explicit Helper(Memory &memory, std::string_view endpoint, std::span<const Target> targets, std::span<const ProcessIdentity> processes = {}, Direction direction = Direction::outbound)
      : memory_(memory), endpoint_(endpoint, AllocatorRef<char, Memory>{memory}), direction_(direction) {
    if (processes.size() > selected_processes_.size()) { throw std::invalid_argument{"Too many selected processes"}; }
    if (targets.empty() || (allowsIncoming(direction) && !processes.empty())) { throw std::invalid_argument{"Incoming redirect selects local services by account; process selection is outbound only"}; }
    const auto incoming = LocalAddresses::selection(targets, direction);
    std::ranges::copy(processes, selected_processes_.begin());
    process_count_ = processes.size();
    endpoint_ += socket_suffix;
    for (const auto &target : targets) {
      listeners_[count_].emplace(target, incoming[count_]);
      mappings_[count_] = listeners_[count_]->mapping();
      ++count_;
    }
  }

  String<Memory> plan(uid_t uid, const PfIdentity<Memory> &identity, bool dry_run = false) {
    std::array<FlowKey, maximum_flows> keys;
    std::array<FlowKey, maximum_flows> incoming;
    std::array<Bypass, maximum_flows> bypasses;
    std::size_t size = 0;
    std::size_t bypass_size = 0;
    std::size_t incoming_size = 0;
    for (const auto &flow : flows_) {
      if (flow && flow->bypass) { bypasses[bypass_size++] = {.key = flow->key, .route = *flow->bypass}; }
      else if (flow && flow->incoming) { incoming[incoming_size++] = flow->key; }
      else if (flow) { keys[size++] = flow->key; }
    }
    const PfScope scope{.uid = uid, .label = identity.label, .discovery_interface = discovery_ ? discovery_->name() : "utun0", .flows = std::span{keys}.first(size), .log_interface = packet_log_ ? std::optional{packet_log_->index()} : dry_run && allowsIncoming(direction_) ? std::optional{0u} : std::nullopt, .bypasses = std::span{bypasses}.first(bypass_size), .log_all = process_count_ != 0 || allowsIncoming(direction_), .direction = direction_, .incoming_flows = std::span{incoming}.first(incoming_size)};
    return pfRules(memory_, std::span{mappings_}.first(count_), scope);
  }

  void run(const PfIdentity<Memory> &identity) {
    if (::geteuid() != 0) {
      throw std::invalid_argument{"Transparent redirection requires the privileged helper"};
    }
    ShutdownSignals signals;
    auto monitor = traffic::connect(endpoint_);
    uid_t uid;
    const auto credentials = peerCredentials(monitor.get());
    if (!credentials || (uid = credentials->user) == 0) { throw SystemError{"Redirect runtime must belong to an unprivileged account", EACCES}; }
    if (process_count_ != 0) { owners_.emplace(uid, std::span{selected_processes_}.first(process_count_)); }
    if (allowsIncoming(direction_)) { accounts_.emplace(memory_); accounts_->validate(); }
    std::array<Byte, Protocol::frame_bytes> hello;
    traffic::sendAll(monitor.get(), Protocol::encode(hello, Kind::monitor, {}));
    std::array<Byte, sizeof(std::uint32_t)> reply;
    readAll(monitor.get(), reply);
    plugins::FrameReader reader{reply};
    if (reader.integer<std::uint32_t>() != uid) { throw EncodingError{"Redirect runtime account does not match its socket credentials"}; }
    discovery_.emplace();
    nat_.emplace();
    Record state{memory_, identity, endpoint_};
    PfCommand command{memory_};
    PfLoopback interface{command};
    SharedLoopback loopback{memory_, interface, identity.label};
    PfSession session{command, state, identity, loopback};
    session.start(plan(uid, identity));
    if (owners_ || allowsIncoming(direction_) || std::ranges::any_of(std::span{mappings_}.first(count_), [](const auto &mapping) { return mapping.target.host.view() == "::1"; })) {
      packet_log_.emplace(state, uid, direction_);
      session.replace(plan(uid, identity));
      std::fprintf(stderr, "telar redirect: TCP discovery on pflog%u\n", packet_log_->index());
    }
    std::fprintf(stderr, "telar redirect: active for uid %u, %zu TCP destinations, anchor %s, discovery %.*s\n", uid, count_, identity.anchor.c_str(), static_cast<int>(discovery_->name().size()), discovery_->name().data());
    const auto active = static_cast<Byte>(MonitorUpdate::active);
    traffic::sendAll(monitor.get(), {&active, 1});
    while (!signals.stopping()) {
      std::array<pollfd, pending_offset + maximum_pending + maximum_flows> descriptors{};
      descriptors[0] = {.fd = monitor.get(), .events = POLLIN, .revents = 0};
      descriptors[1] = {.fd = discovery_->descriptor(), .events = POLLIN, .revents = 0};
      descriptors[2] = {.fd = packet_log_ ? packet_log_->descriptor() : -1, .events = POLLIN, .revents = 0};
      for (std::size_t index = 0; index < Target::maximum_targets; ++index) {
        descriptors[index + 3] = {.fd = listeners_[index] ? listeners_[index]->descriptor() : -1, .events = POLLIN, .revents = 0};
      }
      for (std::size_t index = 0; index < pending_.size(); ++index) {
        descriptors[pending_offset + index] = {.fd = pending_[index] ? pending_[index]->connection.origin.get() : -1, .events = POLLOUT, .revents = 0};
      }
      for (std::size_t index = 0; index < flows_.size(); ++index) {
        descriptors[pending_offset + maximum_pending + index] = {.fd = flows_[index] ? flows_[index]->lifetime.get() : -1, .events = POLLIN, .revents = 0};
      }
      constexpr int poll_ms = 100;
      if (::poll(descriptors.data(), descriptors.size(), poll_ms) < 0 && errno != EINTR) {
        throw SystemError{"Poll transparent TCP helper"};
      }
      if (descriptors[0].revents & POLLIN) {
        Byte command;
        const auto received = ::recv(monitor.get(), &command, 1, 0);
        if (received == 1 && command != stop_request) { throw EncodingError{"Invalid redirect stop request"}; }
        break;
      }
      if (descriptors[0].revents & (POLLHUP | POLLERR | POLLNVAL)) {
        break;
      }
      bool changed = false;
      for (std::size_t index = 0; index < flows_.size(); ++index) {
        if (flows_[index] && ((descriptors[pending_offset + maximum_pending + index].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) || std::chrono::steady_clock::now() >= flows_[index]->deadline)) {
          flows_[index].reset();
          changed = true;
        }
      }
      if (changed) { session.replace(plan(uid, identity)); }
      for (std::size_t index = 0; index < count_; ++index) {
        if (descriptors[index + 3].revents & POLLIN) {
          accept(*listeners_[index], uid);
        }
      }
      for (std::size_t index = 0; index < pending_.size(); ++index) {
        auto &pending = pending_[index];
        if (!pending) {
          continue;
        }
        if (!flows_[pending->flow]) {
          pending.reset();
          continue;
        }
        if (descriptors[pending_offset + index].revents & (POLLOUT | POLLERR | POLLHUP)) {
          int failure = 0;
          socklen_t length = sizeof(failure);
          if (::getsockopt(pending->connection.origin.get(), SOL_SOCKET, SO_ERROR, &failure, &length) == 0 && failure == 0) {
            handoff(pending->connection, pending->flow, uid);
          } else if (flows_[pending->flow]->incoming) {
            std::fprintf(stderr, "telar redirect: incoming origin connection failed: %s\n", std::strerror(failure ? failure : errno));
          }
          pending.reset();
        } else if (std::chrono::steady_clock::now() >= pending->deadline) {
          if (flows_[pending->flow]->incoming) { std::fprintf(stderr, "telar redirect: incoming origin connection timed out\n"); }
          pending.reset();
        }
      }
      if (descriptors[1].revents & POLLIN) {
        discover(session, uid, identity);
      }
      if (packet_log_) {
        for (std::size_t count = 0; count < maximum_accept_batch; ++count) {
          auto packet = packet_log_->receive();
          if (packet.empty()) { break; }
          discovered(session, uid, identity, packet, &packet_log_->metadata());
        }
      }
    }
    packet_log_.reset();
    session.stop();
    const auto stopped = static_cast<Byte>(MonitorUpdate::stopped);
    ::send(monitor.get(), &stopped, 1, 0);
  }

private:
  template <typename Session>
  void discover(Session &session, uid_t uid, const PfIdentity<Memory> &identity) {
    std::array<Byte, 65540> bytes;
    auto packet = discovery_->receive(bytes);
    if (packet.empty()) { return; }
    if (owners_ || allowsIncoming(direction_)) { return; }
    discovered(session, uid, identity, packet);
  }

  template <typename Session>
  void discovered(Session &session, uid_t uid, const PfIdentity<Memory> &identity, std::span<Byte> packet, const PacketLog::Metadata *metadata = nullptr) {
    const auto key = FlowKey::syn(packet);
    const bool incoming = metadata && metadata->incoming;
    if (!key || (incoming ? !allowsIncoming(direction_) : !allowsOutgoing(direction_)) || !std::ranges::any_of(std::span{mappings_}.first(count_), [&](const auto &mapping) { return (!incoming || mapping.incoming) && FlowKey::same(mapping.target, key->destination); })) {
      std::fprintf(stderr, "telar redirect: rejected unsupported discovery packet\n");
      return;
    }
    if (incoming && (metadata->interface_index == 0 || metadata->interface.view() == "lo0" || metadata->interface.view() == discovery_->name() || !LocalAddresses{}.contains(key->destination))) { throw SystemError{"Incoming redirect destination/interface is no longer local", EADDRNOTAVAIL}; }
    const auto found = std::ranges::find_if(flows_, [&](const auto &flow) { return flow && flow->incoming == incoming && flow->key.matches(*key); });
    if (found == flows_.end()) {
      const auto empty = std::ranges::find_if(flows_, [](const auto &flow) { return !flow; });
      if (empty == flows_.end()) { return; }
      Flow flow{.key = *key, .incoming = incoming};
      if (owners_) {
        const auto owner = owners_->find(*key);
        if (!owner.process) {
          if (!metadata || metadata->interface_index == 0) { throw SystemError{"Original process route is unavailable", ENXIO}; }
          flow.bypass = RoutePath::lookup(key->destination, metadata->interface_index);
          flow.deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
          if (!owner.complete) { std::fprintf(stderr, "telar redirect: incomplete process ownership lookup; retaining the direct route\n"); }
        }
      }
      empty->emplace(std::move(flow));
      session.replace(plan(uid, identity));
      std::fprintf(stderr, "telar redirect: discovered TCP flow for destination port %u\n", key->destination.port);
    }
    discovery_->inject(packet);
  }

  static void readAll(int socket, std::span<Byte> bytes) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
    while (!bytes.empty()) {
      pollfd descriptor{.fd = socket, .events = POLLIN, .revents = 0};
      constexpr int poll_ms = 50;
      if (::poll(&descriptor, 1, poll_ms) > 0) {
        const auto count = ::recv(socket, bytes.data(), bytes.size(), MSG_DONTWAIT);
        if (count > 0) {
          bytes = bytes.subspan(static_cast<std::size_t>(count));
        } else if (count == 0 || !socketWouldBlock(errno)) {
          throw SystemError{"Redirect runtime disconnected", ECONNRESET};
        }
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"Redirect runtime reply timed out", ETIMEDOUT};
      }
    }
  }

  void accept(const Listener &listener, uid_t uid) {
    for (std::size_t round = 0; round < maximum_accept_batch; ++round) {
      auto child = listener.accept();
      if (!child) {
        return;
      }
      auto slot = std::ranges::find_if(pending_, [](const auto &value) { return !value; });
      if (slot == pending_.end()) {
        continue;
      }
      const auto target = listener.mapping().target;
      const auto flow = std::ranges::find_if(flows_, [&](const auto &value) { return value && !value->bypass && !value->accepted && FlowKey::same(value->key.destination, target) && NatLookup::peerMatches(child.get(), value->key); });
      if (flow == flows_.end() || !nat_->matches(child.get(), (*flow)->key)) {
        std::fprintf(stderr, "telar redirect: rejected connection without selected NAT state\n");
        continue;
      }
      const auto index = static_cast<std::size_t>(flow - flows_.begin());
      if (owners_ && !owners_->find((*flow)->key).process) { std::fprintf(stderr, "telar redirect: selected process no longer owns the accepted socket\n"); continue; }
      (*flow)->accepted = true;
      if ((*flow)->incoming) { std::fprintf(stderr, "telar redirect: accepted incoming TCP for destination port %u\n", target.port); }
      Connection connection{.child = std::move(child), .origin = openOriginSocket(target.endpoint.storage.ss_family), .target = target};
      if (::connect(connection.origin.get(), target.endpoint.address(), target.endpoint.length) == 0) {
        handoff(connection, index, uid);
      } else if (errno == EINPROGRESS || errno == EINTR) {
        slot->emplace(Pending{.connection = std::move(connection), .deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10}, .flow = index});
      } else if ((*flow)->incoming) {
        std::fprintf(stderr, "telar redirect: incoming origin connection failed: %s\n", std::strerror(errno));
      }
    }
  }

  void handoff(const Connection &connection, std::size_t flow, uid_t uid) {
    if (flows_[flow]->incoming && (!accounts_ || accounts_->peer(connection.origin.get()) != uid)) {
      std::fprintf(stderr, "telar redirect: rejected incoming origin without the runtime account\n");
      flows_[flow]->deadline = std::chrono::steady_clock::now();
      return;
    }
    auto channel = traffic::connect(endpoint_);
    Protocol::send(channel.get(), connection);
    std::array<Byte, 1> admitted{};
    readAll(channel.get(), admitted);
    if (admitted[0] != 1) {
      std::fprintf(stderr, "telar redirect: runtime connection capacity reached\n");
      return;
    }
    flows_[flow]->lifetime = std::move(channel);
    flows_[flow]->deadline = std::chrono::steady_clock::time_point::max();
    if (flows_[flow]->incoming) { std::fprintf(stderr, "telar redirect: handed incoming TCP to runtime for destination port %u\n", connection.target.port); }
  }

  static constexpr std::size_t maximum_pending = 32;
  static constexpr std::size_t maximum_accept_batch = 16;
  static constexpr std::size_t maximum_flows = 256;
  static constexpr std::size_t pending_offset = 3 + Target::maximum_targets;
  Memory &memory_;
  String<Memory> endpoint_;
  std::array<std::optional<Listener>, Target::maximum_targets> listeners_;
  std::array<Mapping, Target::maximum_targets> mappings_;
  std::array<std::optional<Pending>, maximum_pending> pending_;
  std::array<std::optional<Flow>, maximum_flows> flows_;
  std::optional<Discovery> discovery_;
  std::optional<NatLookup> nat_;
  std::optional<PacketLog> packet_log_;
  std::optional<SocketOwners> owners_;
  std::optional<SocketAccounts<Memory>> accounts_;
  std::array<ProcessIdentity, SocketOwners::maximum_processes> selected_processes_;
  std::size_t process_count_ = 0;
  std::size_t count_ = 0;
  Direction direction_ = Direction::outbound;
};

}
