#pragma once

#include "../memory/allocator.hpp"
#include "../memory/erasing_allocator.hpp"
#include "../memory/sensitive_buffer.hpp"
#include "../memory/drop_channel.hpp"
#include "../plugins/protocol.hpp"
#include "../platform/completion_signal.hpp"
#include "../platform/local_listener.hpp"
#include "filter.hpp"
#include <chrono>
#include <poll.h>
#include <thread>

namespace telar::runtime::traffic {

template <ConcurrentAllocator Memory>
class Service {
  using SensitiveMemory = ErasingAllocator<Memory>;
  using Bytes = Vector<Byte, SensitiveMemory>;

  struct Frame {
    explicit Frame(SensitiveMemory &memory, std::span<const Byte> input) : bytes(input.begin(), input.end(), AllocatorRef<Byte, SensitiveMemory>{memory}) {}
    Bytes bytes;
  };

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
    std::chrono::steady_clock::time_point connected = std::chrono::steady_clock::now();
  };

public:
  explicit Service(Memory &memory, std::string_view path) : memory_(memory), listener_(path) {
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

  bool listening() const noexcept { return exchange_subscribers_.load(std::memory_order_acquire) != 0; }

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
    std::array<pollfd, Limits::subscribers + 3> descriptors{};
    descriptors[0] = {.fd = listener_.descriptor(), .events = POLLIN, .revents = 0};
    descriptors[1] = {.fd = wake_.descriptor(), .events = POLLIN, .revents = 0};
    for (std::size_t index = 0; index < peers_.size(); ++index) {
      const auto &peer = peers_[index];
      descriptors[index + 2] = {.fd = peer ? peer->socket.get() : -1, .events = static_cast<short>(POLLIN | (peer && peer->count ? POLLOUT : 0)), .revents = 0};
    }

    constexpr int heartbeat_ms = 1000;
    const auto result = ::poll(descriptors.data(), descriptors.size(), heartbeat_ms);
    if (result < 0 && errno != EINTR) {
      throw SystemError{"Poll traffic sockets"};
    }
    if (stopping_.load(std::memory_order_acquire)) {
      return;
    }
    if (descriptors[1].revents & POLLIN) {
      wake_.drain();
      while (auto frame = injections_.tryReceive()) {
        const auto event = Protocol::decode((*frame)->bytes);
        publish(event, std::move(*frame));
      }
    }

    for (std::size_t index = 0; index < peers_.size(); ++index) {
      auto &peer = peers_[index];
      if (!peer) {
        continue;
      }
      const auto ready = descriptors[index + 2].revents;
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
        const bool producer = peer->role && *peer->role != Role::subscribe;
        if (peer->role == Role::subscribe && peer->selection != Selection::packets) {
          exchange_subscribers_.fetch_sub(1, std::memory_order_release);
        }
        peer.reset();
        if (producer) {
          producer_ = false;
          publish(Event{.kind = Kind::capture_stopped});
        }
      }
    }

    if (descriptors[0].revents & POLLIN) {
      accept();
    }

    const auto now = std::chrono::steady_clock::now();
    if (now - heartbeat_ >= std::chrono::seconds{1}) {
      publish(Event{.kind = Kind::statistics, .runtime_drops = injections_.metrics().dropped + allocation_drops_.load(std::memory_order_relaxed)});
      heartbeat_ = now;
    }
  }

  void accept() {
    auto socket = listener_.accept(LocalPeerPolicy::same_user_or_root);
    if (!socket) {
      return;
    }

    uid_t uid;
    gid_t gid;
    if (::getpeereid(socket.get(), &uid, &gid) != 0) {
      return;
    }
    for (auto &slot : peers_) {
      if (!slot) {
        slot.emplace(memory_, std::move(socket), uid);
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
          if (size == 0 || size > Limits::frame_bytes || reader.integer<std::uint64_t>() != 0) {
            throw EncodingError{"Invalid capture frame prefix"};
          }
          peer.expected = size;
          peer.input.clear();
          continue;
        }

        auto event = Protocol::decode(peer.input);
        if (event.kind == Kind::exchange) {
          throw EncodingError{"Capture helpers cannot publish decrypted exchanges"};
        }
        event.offline = *peer.role == Role::offline_capture;
        publish(event);
      }

      peer.input.clear();
      peer.expected = Protocol::prefix_bytes;
    }
  }

  bool greet(Peer &peer) {
    std::span<const Byte> input{peer.input};
    if (LittleEndian<std::uint32_t>::decode(input) != Protocol::magic) {
      throw EncodingError{"Incompatible traffic protocol"};
    }
    const auto role = LittleEndian<Byte>::decode(input);
    const auto selection = LittleEndian<Byte>::decode(input);
    const auto size = LittleEndian<std::uint32_t>::decode(input);
    if (role < static_cast<Byte>(Role::subscribe) || role > static_cast<Byte>(Role::offline_capture) || selection < static_cast<Byte>(Selection::packets) || selection > static_cast<Byte>(Selection::both) || size > Limits::filter_bytes) {
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
    peer.selection = static_cast<Selection>(selection);
    if (selected == Role::subscribe) {
      const auto subscribers = std::ranges::count_if(peers_, [](const auto &slot) { return slot && slot->role == Role::subscribe; });
      if (static_cast<std::size_t>(subscribers) >= Limits::subscribers || peer.uid != ::geteuid()) {
        throw EncodingError{"Traffic subscription is unavailable"};
      }
      peer.filter.emplace(std::string_view{reinterpret_cast<const char *>(input.data()), input.size()});
      if (peer.selection != Selection::packets) {
        exchange_subscribers_.fetch_add(1, std::memory_order_release);
      }
    } else {
      if (producer_ || size != 0 || (selected == Role::live_capture && peer.uid != 0)) {
        throw EncodingError{"Traffic capture requires one authorized helper"};
      }
      producer_ = true;
    }
    peer.role = selected;
    enqueue(peer, encode(Event{.kind = Kind::ready}));
    if (selected != Role::subscribe) {
      publish(Event{.kind = Kind::capture_started, .offline = selected == Role::offline_capture});
    }
    return true;
  }

  std::shared_ptr<Frame> encode(const Event &event) {
    SensitiveBuffer<Limits::frame_bytes> output;
    return std::allocate_shared<Frame>(AllocatorRef<Frame, SensitiveMemory>{memory_}, memory_, Protocol::encode(output.bytes(), event));
  }

  void publish(const Event &event, std::shared_ptr<Frame> shared = {}) {
    for (auto &peer : peers_) {
      if (!peer || peer->role != Role::subscribe || peer->failed) {
        continue;
      }
      try {
        if ((event.kind == Kind::packet && peer->selection == Selection::exchanges) || (event.kind == Kind::exchange && peer->selection == Selection::packets)) {
          continue;
        }
        if (!peer->filter->matches(event)) {
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
    delivery.prefix = Protocol::prefix(frame->bytes.size(), peer.dropped);
    delivery.frame = std::move(frame);
    delivery.offset = 0;
    ++peer.count;
  }

  static void write(Peer &peer) {
    for (std::size_t round = 0; round < Limits::pending_frames && peer.count != 0; ++round) {
      auto &delivery = peer.queue[peer.head];
      const auto prefix = std::span<const Byte>{delivery.prefix};
      const auto body = std::span<const Byte>{delivery.frame->bytes};
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

  SensitiveMemory memory_;
  LocalListener listener_;
  CompletionSignal wake_;
  std::atomic<bool> stopping_{false};
  std::array<std::optional<Peer>, Limits::subscribers + 1> peers_{};
  pthread_t thread_{};
  std::chrono::steady_clock::time_point heartbeat_ = std::chrono::steady_clock::now();
  bool producer_ = false;
  DropChannel<std::shared_ptr<Frame>, Limits::pending_frames> injections_;
  std::atomic<std::uint64_t> exchange_subscribers_{0};
  std::atomic<std::uint64_t> allocation_drops_{0};
  std::atomic<std::uint64_t> next_exchange_{1};
  std::uint64_t session_ = 0;
};

}
