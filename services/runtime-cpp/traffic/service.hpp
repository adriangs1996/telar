#include "telar_platform/peer_credentials.hpp"
#pragma once

#include "../platform/completion_signal.hpp"
#include "../platform/local_listener.hpp"
#include "../plugins/protocol.hpp"
#include "../proxy/socket.hpp"
#include "capture_analysis.hpp"
#include "control_access.hpp"
#include "filter.hpp"
#include "interception.hpp"
#include "package_port.hpp"
#include "recordings.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/drop_channel.hpp"
#include "telar_base/memory/erasing_allocator.hpp"
#include "telar_base/memory/sensitive_allocation.hpp"
#include "telar_base/memory/sensitive_buffer.hpp"
#include <chrono>
#include <poll.h>
#include <thread>

namespace telar::runtime::traffic {

template <ConcurrentAllocator Memory>
class Service : public FlowControl, public HttpControl, public PackagePort {
  using SensitiveMemory = ErasingAllocator<Memory>;
  using Bytes = Vector<Byte, SensitiveMemory>;
  static constexpr std::size_t maximum_peers = Limits::subscribers * 2 + 1;

  using Frame = EventFrame<Memory>;

  struct Delivery {
    std::shared_ptr<Frame> frame;
    std::array<Byte, Protocol::prefix_bytes> prefix;
    std::size_t offset = 0;
  };

  struct Peer {
    explicit Peer(SensitiveMemory &memory, FileDescriptor socket, uid_t uid)
        : socket(std::move(socket)), uid(uid), input(AllocatorRef<Byte, SensitiveMemory>{memory}) {}

    FileDescriptor socket;
    uid_t uid;
    Bytes input;
    std::optional<Role> role;
    Selection selection = Selection::both;
    std::optional<Filter> filter;
    std::array<Delivery, Limits::pending_frames> queue;
    std::size_t head = 0;
    std::size_t count = 0;
    std::size_t expected = Protocol::greeting_bytes;
    std::uint64_t dropped = 0;
    bool failed = false;
    bool configured = false;
    bool http = false;
    std::uint64_t owner = 0;
    struct PackageIdentity {
      std::uint64_t id;
      plugins::PackageDigest digest;
      std::uint64_t generation;
      bool observe;
      bool intercept;
      std::uint64_t order;
      std::shared_ptr<std::atomic<bool>> permission;
    };
    std::optional<PackageIdentity> package;
    std::chrono::steady_clock::time_point connected = std::chrono::steady_clock::now();
  };

  struct Attachment {
    FileDescriptor socket;
    typename Peer::PackageIdentity package;
    std::uint64_t owner;
  };

public:
  explicit Service(Memory &memory, std::string_view path, bool allow_interception = false) : upstream_(memory), memory_(memory), listener_(path), interception_(memory), http_interception_(memory, &interception_.completionSignal(), &interception_.requestSignal()), analysis_(memory), recordings_(memory), allow_interception_(allow_interception) {
    ::arc4random_buf(&session_, sizeof(session_));
    const auto error = ::pthread_create(&thread_, nullptr, &start, this);
    if (error != 0) {
      throw SystemError{"Start traffic service", error};
    }
  }

  ~Service() {
    stopping_.store(true, std::memory_order_release);
    wake_.notify();
    ::pthread_join(thread_, nullptr);
  }

  Service(const Service &) = delete;
  Service &operator=(const Service &) = delete;

  bool listening() const noexcept { return exchange_subscribers_.load(std::memory_order_acquire) != 0 || recordings_.selects(Selection::exchanges); }

  std::span<const Byte> recording(const recording::Request &request, std::span<Byte> output, recording::Owner owner = {}) { return recordings_.handle(request, output, std::move(owner)); }

  void packageControl(control::PackagePort *port) noexcept { package_control_.store(port, std::memory_order_release); }

  FileDescriptor openControl(const plugins::ServiceSpec &package) override {
    const auto port = package_control_.load(std::memory_order_acquire);
    if (!port) { throw SystemError{"Package control is starting", EAGAIN}; }
    return port->openPackage(package);
  }

  void revokePackage(const plugins::ServiceSpec &package) noexcept override { recordings_.revoke(recording::Owner::package(package)); }

  PackageChannel openPackage(const plugins::ServiceSpec &specification, std::uint32_t registration = 0) override {
    const bool observe = specification.allows(plugins::Capability::traffic_observe);
    const bool intercept = specification.allows(plugins::Capability::traffic_intercept);
    if ((!observe && !intercept) || specification.plugin_id == 0 || specification.generation == 0) { throw EncodingError{"Package has no granted traffic capability"}; }
    std::array<int, 2> descriptors;
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors.data()) != 0) { throw SystemError{"Create package traffic channel"}; }
    FileDescriptor native{descriptors[0]}, client{descriptors[1]};
    configureProxySocket(native.get());
    configureProxySocket(client.get());
    const auto order = (static_cast<std::uint64_t>(specification.package_index) << 32) | registration;
    const auto owner = ++next_owner_;
    if (!attachments_.publish(Attachment{std::move(native), {specification.plugin_id, specification.digest, specification.generation, observe, intercept, order, specification.permission}, owner})) { throw SystemError{"Package traffic attachment queue is full", EBUSY}; }
    wake_.notify();
    return {std::move(client), owner};
  }

  void setPackageAvailable(std::uint64_t owner, bool available) noexcept override {
    interception_.setAvailable(owner, available);
    http_interception_.setAvailable(owner, available);
  }

  bool packagePending(std::uint64_t owner, std::uint64_t ticket, bool http) noexcept override {
    return http ? http_interception_.pending(owner, ticket) : interception_.pending(owner, ticket);
  }

  void packageFailure(const plugins::ServiceSpec &specification, FlowEvent event) noexcept override {
    std::array<char, 128> reason;
    const auto name = specification.name.view();
    const auto length = std::snprintf(reason.data(), reason.size(), "app_callback_error:%.*s", static_cast<int>(name.size()), name.data());
    event.reason = {reason.data(), length > 0 ? std::min(static_cast<std::size_t>(length), reason.size() - 1) : 0};
    event.bytes = {};
    observeFlow(Kind::flow_error, event);
  }

  enum class CaptureState : Byte { idle, live, offline };
  struct CaptureStatus {
    CaptureState state;
    std::uint64_t session;
    std::uint32_t interfaces;
    std::uint32_t interface_errors;
  };

  CaptureStatus captureStatus() const noexcept {
    std::lock_guard lock{capture_mutex_};
    return capture_status_;
  }

  std::uint64_t stopCapture() noexcept {
    const auto revision = capture_stop_.fetch_add(1, std::memory_order_release) + 1;
    wake_.notify();
    return revision;
  }

  bool captureStopped(std::uint64_t revision) const noexcept { return capture_stopped_.load(std::memory_order_acquire) >= revision; }

  void submit(CapturedExchange<Memory> &exchange) noexcept {
    if (!listening()) {
      return;
    }

    try {
      SensitiveBuffer<Limits::frame_bytes> output;
      const auto sequence = next_exchange_.fetch_add(1, std::memory_order_relaxed);
      const auto payload = plugins::Protocol::encodeExchange(output.bytes(), {sequence, session_}, exchange, Limits::http_part_bytes);
      auto frame = encode(Event{.kind = Kind::exchange, .session = session_, .sequence = sequence, .bytes = payload});
      injections_.publish(std::move(frame));
      wake_.notify();
    } catch (const std::exception &) {
      allocation_drops_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  void observeFlow(Kind kind, const FlowEvent &flow) noexcept override {
    if (kind != Kind::intercept_request && flow_subscribers_.load(std::memory_order_acquire) == 0 && !recordings_.selects(Selection::flows)) {
      return;
    }
    try {
      SensitiveBuffer<FlowControl::chunk_bytes + Limits::metadata_bytes> output;
      const auto payload = FlowCodec::encode(output.bytes(), flow);
      const auto now = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
      auto frame = encode(Event{.kind = kind, .session = session_, .sequence = next_exchange_.fetch_add(1, std::memory_order_relaxed), .timestamp_us = static_cast<std::uint64_t>(now), .bytes = payload});
      injections_.publish(std::move(frame));
      wake_.notify();
    } catch (const std::exception &) {
      allocation_drops_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  std::uint64_t intercept(const FlowEvent &event) noexcept override {
    return interception_.begin(event);
  }

  Decision poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept override { return interception_.poll(ticket, replacement); }
  void cancel(std::uint64_t ticket) noexcept override { interception_.cancel(ticket); }
  std::optional<Time> deadline(std::uint64_t ticket) noexcept override { return interception_.deadline(ticket); }
  int descriptor() const noexcept override { return interception_.descriptor(); }
  void drain() noexcept override { interception_.drain(); }
  HttpControl *http() noexcept override { return allow_interception_ ? this : nullptr; }
  HttpPolicy policy(const FlowEvent &context) noexcept override { return http_interception_.policy(context); }
  std::uint64_t interceptHttp(const FlowEvent &event) noexcept override { return http_interception_.begin(event); }
  Decision pollHttp(std::uint64_t ticket, std::span<Byte> replacement) noexcept override { return http_interception_.poll(ticket, replacement); }
  void cancelHttp(std::uint64_t ticket) noexcept override { http_interception_.cancel(ticket); }
  std::optional<Time> httpDeadline(std::uint64_t ticket) noexcept override { return http_interception_.deadline(ticket); }
  void httpUnavailable(const FlowEvent &event) noexcept override { observeFlow(Kind::flow_error, event); }

private:
  static void *start(void *context) noexcept {
    static_cast<Service *>(context)->run();
    return nullptr;
  }

  void run() noexcept {
    while (!stopping_.load(std::memory_order_acquire)) {
      try {
        step();
      } catch (const std::exception &error) {
        std::fprintf(stderr, "telar traffic: %s\n", error.what());
      }
    }
  }

  void step() {
    std::array<pollfd, maximum_peers + 3> descriptors{};
    descriptors[0] = {.fd = listener_.descriptor(), .events = POLLIN, .revents = 0};
    descriptors[1] = {.fd = wake_.descriptor(), .events = POLLIN, .revents = 0};
    descriptors[2] = {.fd = interception_.requestDescriptor(), .events = POLLIN, .revents = 0};
    for (std::size_t index = 0; index < peers_.size(); ++index) {
      const auto &peer = peers_[index];
      descriptors[index + 3] = {.fd = peer ? peer->socket.get() : -1, .events = static_cast<short>(POLLIN | (peer && peer->count ? POLLOUT : 0)), .revents = 0};
    }

    constexpr int heartbeat_ms = 1000;
    const auto result = ::poll(descriptors.data(), descriptors.size(), heartbeat_ms);
    if (result < 0 && errno != EINTR) {
      throw SystemError{"Poll traffic sockets"};
    }
    if (stopping_.load(std::memory_order_acquire)) {
      return;
    }
    const auto stop_capture = capture_stop_.load(std::memory_order_acquire);
    if (stop_capture != capture_stopped_.load(std::memory_order_relaxed)) {
      for (auto &peer : peers_) {
        if (peer && (peer->role == Role::live_capture || peer->role == Role::offline_capture)) { peer->failed = true; }
      }
    }
    if (descriptors[1].revents & POLLIN) {
      wake_.drain();
      while (auto attachment = attachments_.tryReceive()) {
        for (auto &slot : peers_) {
          if (!slot) {
            slot.emplace(memory_, std::move(attachment->socket), ::geteuid());
            slot->package = attachment->package;
            slot->owner = attachment->owner;
            break;
          }
        }
      }
      while (auto frame = injections_.tryReceive()) {
        const auto event = Protocol::decode((*frame)->bytes.bytes());
        publish(event, std::move(*frame));
      }
    }

    if (descriptors[2].revents & POLLIN) {
      interception_.drainRequests();
    }

    for (std::size_t index = 0; index < peers_.size(); ++index) {
      auto &peer = peers_[index];
      if (!peer) {
        continue;
      }
      const auto ready = descriptors[index + 3].revents;
      try {
        if (ready & (POLLIN | POLLHUP)) {
          read(*peer);
        }
        if (ready & POLLOUT) {
          write(*peer);
        }
      } catch (const std::exception &) {
        peer->failed = true;
      }

      constexpr auto handshake_timeout = std::chrono::seconds{5};
      const bool expired = !peer->role && std::chrono::steady_clock::now() - peer->connected >= handshake_timeout;
      if (peer->failed || expired || (ready & (POLLERR | POLLNVAL))) {
        const bool producer = peer->role == Role::live_capture || peer->role == Role::offline_capture;
        if (peer->role == Role::intercept) {
          interception_.disconnect(peer->owner);
          http_interception_.disconnect(peer->owner);
        }
        if (peer->role == Role::subscribe && selects(peer->selection, Selection::exchanges)) {
          exchange_subscribers_.fetch_sub(1, std::memory_order_release);
        }
        if (peer->role == Role::subscribe && selects(peer->selection, Selection::flows)) {
          flow_subscribers_.fetch_sub(1, std::memory_order_release);
        }
        if (peer->role == Role::subscribe && selects(peer->selection, Selection::datagrams)) {
          datagram_subscribers_.fetch_sub(1, std::memory_order_release);
        }
        peer.reset();
        if (producer) {
          producer_ = false;
          {
            std::lock_guard lock{capture_mutex_};
            capture_status_ = {};
          }
          analysis_.expire([&](const Event &event) { publish(event); }, true);
          publish(Event{.kind = Kind::capture_stopped});
        }
      }
    }

    capture_stopped_.store(stop_capture, std::memory_order_release);

    if (descriptors[0].revents & POLLIN) {
      accept();
    }

    for (auto &peer : peers_) {
      if (!peer || peer->failed || !peer->configured || peer->role != Role::intercept) {
        continue;
      }

      auto deliver = [&](const FlowEvent &flow) {
        if (peer->count == peer->queue.size()) {
          return false;
        }

        SensitiveAllocation output{upstream_, flow.bytes.size() + Limits::metadata_bytes};
        const auto payload = FlowCodec::encode(output.bytes(), flow);
        const auto now = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
        enqueue(*peer, encode(Event{.kind = peer->http ? Kind::http_intercept_request : Kind::intercept_request, .session = session_, .sequence = next_exchange_.fetch_add(1, std::memory_order_relaxed), .timestamp_us = static_cast<std::uint64_t>(now), .bytes = payload}));
        return true;
      };
      if (peer->http) { http_interception_.deliver(peer->owner, deliver); }
      else { interception_.deliver(peer->owner, deliver); }
    }

    const auto now = std::chrono::steady_clock::now();
    if (now - heartbeat_ >= std::chrono::seconds{1}) {
      analysis_.expire([&](const Event &event) { publish(event); });
      recordings_.expire();
      publish(Event{.kind = Kind::statistics, .runtime_drops = injections_.metrics().dropped + allocation_drops_.load(std::memory_order_relaxed)});
      heartbeat_ = now;
    }
  }

  void accept() {
    auto socket = listener_.accept(LocalPeerPolicy::same_user_or_root);
    if (!socket) {
      return;
    }

    const auto credentials = peerCredentials(socket.get());
    if (!credentials) {
      return;
    }
    for (auto &slot : peers_) {
      if (!slot) {
        slot.emplace(memory_, std::move(socket), credentials->user);
        return;
      }
    }
  }

  void read(Peer &peer) {
    constexpr std::size_t frames_per_tick = 32;
    for (std::size_t frame = 0; frame < frames_per_tick; ++frame) {
      const auto previous = peer.input.size();
      peer.input.resize(peer.expected);
      const auto count = ::recv(peer.socket.get(), peer.input.data() + previous, peer.expected - previous, 0);
      if (count <= 0) {
        peer.input.resize(previous);
        if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
          peer.failed = true;
        }
        return;
      }
      peer.input.resize(previous + static_cast<std::size_t>(count));
      if (peer.input.size() != peer.expected) {
        return;
      }

      if (!peer.role) {
        if (!greet(peer)) {
          continue;
        }
      } else {
        if (*peer.role == Role::subscribe) {
          throw EncodingError{"Subscribers cannot publish traffic"};
        }

        if (peer.expected == Protocol::prefix_bytes) {
          plugins::FrameReader reader{peer.input};
          const auto size = reader.integer<std::uint32_t>();
          const auto limit = peer.http ? Limits::http_frame_bytes : Limits::frame_bytes;
          if (size == 0 || size > limit || reader.integer<std::uint64_t>() != 0) {
            throw EncodingError{"Invalid capture frame prefix"};
          }
          peer.expected = size;
          peer.input.clear();
          continue;
        }

        if (*peer.role == Role::intercept) {
          control(peer);
          peer.input.clear();
          peer.expected = Protocol::prefix_bytes;
          continue;
        }
        auto event = Protocol::decode(peer.input);
        if (event.kind >= Kind::exchange) {
          throw EncodingError{"Capture helpers cannot publish decrypted exchanges"};
        }
        event.offline = *peer.role == Role::offline_capture;
        if (event.kind != Kind::packet) {
          std::lock_guard lock{capture_mutex_};
          capture_status_.session = event.session;
          if (event.kind == Kind::interface_open) { ++capture_status_.interfaces; }
          else if (event.kind == Kind::interface_closed && capture_status_.interfaces != 0) { --capture_status_.interfaces; }
          else if (event.kind == Kind::interface_error) { ++capture_status_.interface_errors; }
        }
        publish(event);
        if (event.kind == Kind::packet) {
          const bool flows = flow_subscribers_.load(std::memory_order_acquire) != 0 || recordings_.selects(Selection::flows);
          const bool datagrams = datagram_subscribers_.load(std::memory_order_acquire) != 0 || recordings_.selects(Selection::datagrams);
          if (flows || datagrams) {
            const auto selected = static_cast<Selection>((flows ? static_cast<Byte>(Selection::flows) : 0) | (datagrams ? static_cast<Byte>(Selection::datagrams) : 0));
            analysis_.packet(event, selected, [&](const Event &item) { publish(item); });
          }
        }
      }

      peer.input.clear();
      peer.expected = Protocol::prefix_bytes;
    }
  }

  bool greet(Peer &peer) {
    if (peer.package && peer.package->permission && !peer.package->permission->load(std::memory_order_acquire)) { throw EncodingError{"Package traffic permission revoked"}; }
    std::span<const Byte> input{peer.input};
    if (LittleEndian<std::uint32_t>::decode(input) != Protocol::magic) {
      throw EncodingError{"Incompatible traffic protocol"};
    }
    const auto role = LittleEndian<Byte>::decode(input);
    const auto selection = LittleEndian<Byte>::decode(input);
    const auto size = LittleEndian<std::uint32_t>::decode(input);
    if (role < static_cast<Byte>(Role::subscribe) || role > static_cast<Byte>(Role::intercept) || selection < static_cast<Byte>(Selection::packets) || selection > static_cast<Byte>(Selection::all) || size > Limits::filter_bytes) {
      throw EncodingError{"Invalid traffic greeting"};
    }
    if (peer.expected == Protocol::greeting_bytes && size != 0) {
      peer.expected += size;
      return false;
    }
    if (input.size() != size) {
      throw EncodingError{"Truncated traffic filter"};
    }

    const auto selected = static_cast<Role>(role);
    if (peer.package && !((selected == Role::subscribe && peer.package->observe) || (selected == Role::intercept && peer.package->intercept))) {
      throw EncodingError{"Package traffic capability denied"};
    }
    peer.selection = static_cast<Selection>(selection);
    if (selected == Role::subscribe) {
      const auto subscribers = std::ranges::count_if(peers_, [](const auto &slot) { return slot && slot->role == Role::subscribe; });
      if (static_cast<std::size_t>(subscribers) >= Limits::subscribers || peer.uid != ::geteuid()) {
        throw EncodingError{"Traffic subscription is unavailable"};
      }
      peer.filter.emplace(std::string_view{reinterpret_cast<const char *>(input.data()), input.size()});
      if (selects(peer.selection, Selection::flows)) {
        flow_subscribers_.fetch_add(1, std::memory_order_release);
      }
      if (selects(peer.selection, Selection::datagrams)) {
        datagram_subscribers_.fetch_add(1, std::memory_order_release);
      }
      if (selects(peer.selection, Selection::exchanges)) {
        exchange_subscribers_.fetch_add(1, std::memory_order_release);
      }
    } else if (selected == Role::intercept) {
      const auto controllers = std::ranges::count_if(peers_, [](const auto &slot) { return slot && slot->role == Role::intercept; });
      if (!allow_interception_ || static_cast<std::size_t>(controllers) >= Limits::subscribers || size != 0 || peer.uid != ::geteuid()) {
        throw EncodingError{"Stream interception is unavailable"};
      }

      if (peer.owner == 0) { peer.owner = ++next_owner_; }
    } else {
      if (producer_ || size != 0 || (selected == Role::live_capture && peer.uid != 0)) {
        throw EncodingError{"Traffic capture requires one authorized helper"};
      }
      producer_ = true;
    }
    peer.role = selected;
    enqueue(peer, encode(Event{.kind = Kind::ready}));
    if (selected == Role::live_capture || selected == Role::offline_capture) {
      {
        std::lock_guard lock{capture_mutex_};
        capture_status_ = {.state = selected == Role::live_capture ? CaptureState::live : CaptureState::offline};
      }
      publish(Event{.kind = Kind::capture_started, .offline = selected == Role::offline_capture});
    }
    return true;
  }

  void control(Peer &peer) {
    if (peer.package && peer.package->permission && !peer.package->permission->load(std::memory_order_acquire)) { throw EncodingError{"Package traffic permission revoked"}; }
    plugins::FrameReader reader{peer.input};
    const auto command = reader.tag(InterceptionCodec::Command::http_rule);
    if (command == InterceptionCodec::Command::rule || command == InterceptionCodec::Command::http_rule) {
      if (peer.configured) {
        throw EncodingError{"Interception rule already registered"};
      }
      const auto rule = InterceptionCodec::readRule(reader);
      peer.http = command == InterceptionCodec::Command::http_rule;
      const auto order = peer.package ? peer.package->order : UINT64_MAX;
      if (peer.http) { http_interception_.configure(peer.owner, rule, order); }
      else { interception_.configure(peer.owner, rule, order); }
      peer.configured = true;
      enqueue(peer, encode(Event{.kind = Kind::ready}));
    } else if (command == InterceptionCodec::Command::decision && peer.configured) {
      const auto ticket = reader.integer<std::uint64_t>();
      const auto verdict = reader.tag(Verdict::reject);
      const auto bytes = reader.bytes();
      reader.finish();
      if (peer.http) {
        if (verdict == Verdict::replace) { HttpMessageCodec::decode(bytes); }
        http_interception_.decide(peer.owner, ticket, verdict, bytes);
      } else { interception_.decide(peer.owner, ticket, verdict, bytes); }
    } else {
      throw EncodingError{"Interception requires a rule before decisions"};
    }
  }

  std::shared_ptr<Frame> encode(const Event &event) {
    auto frame = std::allocate_shared<Frame>(AllocatorRef<Frame, SensitiveMemory>{memory_}, upstream_, Protocol::encodedSize(event));
    Protocol::encode(frame->bytes.bytes(), event);
    return frame;
  }

  void publish(const Event &event, std::shared_ptr<Frame> shared = {}) {
    shared = recordings_.record(event, std::move(shared));
    for (auto &peer : peers_) {
      if (!peer || peer->failed) {
        continue;
      }
      if (peer->role != Role::subscribe || event.kind == Kind::intercept_request || event.kind == Kind::http_intercept_request) {
        continue;
      }
      try {
        if ((event.kind == Kind::packet && !selects(peer->selection, Selection::packets)) || (event.kind == Kind::exchange && !selects(peer->selection, Selection::exchanges)) || (isFlow(event.kind) && !selects(peer->selection, Selection::flows)) || (event.kind == Kind::datagram && !selects(peer->selection, Selection::datagrams))) {
          continue;
        }
        if (peer->filter && !peer->filter->matches(event)) {
          continue;
        }
        if (!shared) {
          shared = encode(event);
        }
        enqueue(*peer, shared);
      } catch (const std::exception &) {
        peer->failed = true;
      }
    }
  }

  static void enqueue(Peer &peer, std::shared_ptr<Frame> frame) {
    if (peer.count == peer.queue.size()) {
      ++peer.dropped;
      return;
    }

    auto &delivery = peer.queue[(peer.head + peer.count) % peer.queue.size()];
    delivery.prefix = Protocol::prefix(frame->bytes.bytes().size(), peer.dropped);
    delivery.frame = std::move(frame);
    delivery.offset = 0;
    ++peer.count;
  }

  static void write(Peer &peer) {
    for (std::size_t round = 0; round < Limits::pending_frames && peer.count != 0; ++round) {
      auto &delivery = peer.queue[peer.head];
      const auto prefix = std::span<const Byte>{delivery.prefix};
      const auto body = std::span<const Byte>{delivery.frame->bytes.bytes()};
      const auto bytes = delivery.offset < prefix.size() ? prefix.subspan(delivery.offset) : body.subspan(delivery.offset - prefix.size());
      const auto count = ::send(peer.socket.get(), bytes.data(), bytes.size(), 0);
      if (count <= 0) {
        if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
          peer.failed = true;
        }
        return;
      }

      delivery.offset += static_cast<std::size_t>(count);
      if (delivery.offset == prefix.size() + body.size()) {
        delivery.frame.reset();
        peer.head = (peer.head + 1) % peer.queue.size();
        --peer.count;
      }
    }
  }

  Memory &upstream_;
  SensitiveMemory memory_;
  LocalListener listener_;
  CompletionSignal wake_;
  std::atomic<bool> stopping_{false};
  std::array<std::optional<Peer>, maximum_peers> peers_{};
  pthread_t thread_{};
  std::chrono::steady_clock::time_point heartbeat_ = std::chrono::steady_clock::now();
  bool producer_ = false;
  std::atomic<std::uint64_t> next_owner_{0};
  Interception<Memory> interception_;
  Interception<Memory, HttpMessageLimits::message_bytes> http_interception_;
  CaptureAnalysis<Memory> analysis_;
  Recordings<Memory> recordings_;
  bool allow_interception_;
  DropChannel<std::shared_ptr<Frame>, Limits::pending_frames> injections_;
  DropChannel<Attachment, Limits::subscribers, ChannelPolicy::keep_oldest> attachments_;
  std::atomic<std::uint64_t> exchange_subscribers_{0};
  std::atomic<std::uint64_t> flow_subscribers_{0};
  std::atomic<std::uint64_t> datagram_subscribers_{0};
  std::atomic<std::uint64_t> allocation_drops_{0};
  std::atomic<std::uint64_t> next_exchange_{1};
  mutable std::mutex capture_mutex_;
  CaptureStatus capture_status_{};
  std::atomic<std::uint64_t> capture_stop_{0};
  std::atomic<std::uint64_t> capture_stopped_{0};
  std::uint64_t session_ = 0;
  std::atomic<control::PackagePort *> package_control_{nullptr};
};

}
