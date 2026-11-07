module;
#include <new>
#include <vector>
#include <stdlib.h>

#include <exception>
#include <charconv>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <array>
#include <stdexcept>
#include <algorithm>
#include <cstddef>
#include <limits.h>
#include <atomic>
#include <memory>
#include <bit>
#include <cstring>
#include <utility>

#include <cerrno>
#include <chrono>
#include <arpa/inet.h>
#include <mutex>

#include <cassert>
#include <pcap/pcap.h>

#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <csignal>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <string>
#include <unordered_map>
#include <condition_variable>
#include <type_traits>
#include <poll.h>
#include <thread>

#include <concepts>
#include <pthread.h>
#include <limits>
#include <brotli/decode.h>
#include <initializer_list>
#include <zlib.h>
#include <zstd.h>
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
#include <cstdlib>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <openssl/err.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/pem.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/x509.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#include <sys/uio.h>
#include <fcntl.h>
#include <cstdlib>
#include <bitset>
#include <openssl/sha.h>
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <dirent.h>
#include <variant>
#include <netdb.h>
#include <brotli/encode.h>
#include <nghttp2/nghttp2.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <openssl/crypto.h>
#include <ctime>
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
#include <spawn.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <ifaddrs.h>
#include <net/if.h>
#if (defined(__APPLE__))
#include <libproc.h>
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

export module telar.runtime.traffic.control_backend;

export import telar.runtime.plugins.tap_configuration;
export import telar.runtime.traffic.control_protocol;


export import telar.runtime.platform.request_worker;
export import telar.base.memory;
export import telar.config;


export import telar.platform;


export import telar.runtime.plugins.protocol;
export import telar.runtime.traffic.capture;


export import telar.runtime.platform.launch_program;
export import telar.runtime.proxy.relay_direction;
export import telar.runtime.traffic.capture_analysis;


export import telar.runtime.proxy.runtime;
export import telar.runtime.redirect.socket_owners;
export import telar.runtime.redirect.ingress;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: traffic/control_access.cppm
export {
namespace telar::runtime::traffic::control {

inline bool authorized(const plugins::ServiceSpec &package, const Request &request) noexcept {
  if (!package.authorized()) { return false; }
  if (request.operation == Operation::recording) { return package.allows(plugins::Capability::traffic_record); }
  if (request.operation == Operation::status || request.operation == Operation::ca_certificate) { return package.traffic(); }
  return package.allows(plugins::Capability::traffic_control);
}

class PackagePort {
public:
  virtual ~PackagePort() = default;
  virtual FileDescriptor openPackage(const plugins::ServiceSpec &package) = 0;
};

}
}

// Interface: traffic/interception.cppm
export {
namespace telar::runtime::traffic {

inline constexpr std::uint32_t default_timeout_ms = 1000;
inline constexpr std::uint32_t maximum_timeout_ms = 30000;

struct InterceptionRule {
  std::string_view host;
  Byte directions = 3;
  Byte visibility = 2;
  std::uint32_t timeout_ms = default_timeout_ms;
  bool fail_closed = false;
  bool http = false;
};

class InterceptionCodec {
public:
  enum class Command : Byte {
    rule = 1,
    decision = 2,
    http_rule = 3,
  };

  inline static auto rule(std::span<Byte> output, InterceptionRule rule) -> std::span<const Byte> {
    plugins::FrameWriter writer{output};
    writer.tag(rule.http ? Command::http_rule : Command::rule);
    writer.text(rule.host);
    writer.integer(rule.directions);
    writer.integer(rule.visibility);
    writer.integer(rule.timeout_ms);
    writer.boolean(rule.fail_closed);
    return writer.finish();
  }

  inline static auto readRule(plugins::FrameReader &reader) -> InterceptionRule {
    InterceptionRule rule{.host = reader.text(), .directions = reader.integer<Byte>(), .visibility = reader.integer<Byte>(), .timeout_ms = reader.integer<std::uint32_t>(), .fail_closed = reader.boolean()};
    reader.finish();

    if (!ProxyHostname::validPattern(rule.host) || rule.directions == 0 || rule.directions > 3 || rule.visibility == 0 || rule.visibility > 3 || rule.timeout_ms == 0 || rule.timeout_ms > maximum_timeout_ms) {
      throw EncodingError{"Invalid interception rule"};
    }
    return rule;
  }

  inline static auto decision(std::span<Byte> output, std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes = {}) -> std::span<const Byte> {
    plugins::FrameWriter writer{output};
    writer.tag(Command::decision);
    writer.integer(ticket);
    writer.tag(verdict);
    writer.bytes(bytes);
    return writer.finish();
  }
};

// Each chunk snapshots registration order. A new ticket authenticates every step of the chain.
template <ConcurrentAllocator Memory, std::size_t maximum_bytes = FlowControl::chunk_bytes>
class Interception {
  using Secure = ErasingAllocator<Memory>;
  using Owner = std::uint64_t;

  struct Route {
    Owner owner;
    std::uint64_t generation;
    std::uint32_t timeout_ms;
    bool fail_closed;
    std::uint64_t order;
  };

  struct Registration {
    inline Registration(Memory &memory, Owner owner, InterceptionRule rule, std::uint64_t generation, std::uint64_t order) : route{owner, generation, rule.timeout_ms, rule.fail_closed, order}, hosts(memory), directions(rule.directions), visibility(rule.visibility) {
      if (!ProxyHostname::validPattern(rule.host) || rule.directions == 0 || rule.directions > 3 || rule.visibility == 0 || rule.visibility > 3 || rule.timeout_ms == 0 || rule.timeout_ms > maximum_timeout_ms || !hosts.append(rule.host)) {
        throw EncodingError{"Invalid interception rule"};
      }

      hosts.finish();
    }

    Route route;
    ProxyHostPolicy<Memory> hosts;
    Byte directions;
    Byte visibility;
    bool available = true;
  };

  struct Pending {
    inline Pending(Secure &memory, std::uint64_t ticket, const FlowEvent &event, std::span<const Route> matches) : ticket(ticket), decision_ticket(ticket), id(event.id), offset(event.offset), direction(event.direction), visibility(event.visibility), source(event.source), bytes(event.bytes.begin(), event.bytes.end(), AllocatorRef<Byte, Secure>{memory}), routes(matches.size()) {
      client.append(event.client);
      server.append(event.server);
      host.append(event.host);
      reason.append(event.reason);
      std::ranges::copy(matches, chain.begin());
    }

    inline auto event() const noexcept -> FlowEvent {
      return {.id = id, .direction = direction, .visibility = visibility, .source = source, .offset = offset, .ticket = decision_ticket, .client = client.view(), .server = server.view(), .host = host.view(), .reason = reason.view(), .bytes = bytes};
    }

    std::uint64_t ticket;
    std::uint64_t decision_ticket;
    std::uint64_t id;
    std::uint64_t offset;
    Direction direction;
    Visibility visibility;
    FlowSource source;
    FlowControl::Time deadline{};
    SensitiveText<128> client, server, reason;
    SensitiveText<253> host;
    Verdict verdict = Verdict::pending;
    Vector<Byte, Secure> bytes;
    std::array<Route, Limits::subscribers> chain;
    std::size_t routes;
    std::size_t step = 0;
    bool replaced = false;
    bool delivered = false;
  };

public:
  inline explicit Interception(Memory &memory, CompletionSignal *completion = nullptr, CompletionSignal *requests = nullptr)
      : upstream_(memory), memory_(memory), completion_(completion ? *completion : wake_), request_signal_(requests ? *requests : requests_) {
    randomBytes(&next_, sizeof(next_));
    next_ >>= 1;
  }

  inline void configure(InterceptionRule rule) {
    configure(default_owner, rule);
  }

  inline auto policy(const FlowEvent &event) noexcept -> HttpPolicy {
    if (active_.load(std::memory_order_acquire) == 0) { return {}; }
    std::scoped_lock lock{mutex_};
    HttpPolicy result;
    for (const auto &entry : registrations_) {
      if (entry && entry->hosts.contains(event.host) && (entry->directions & (1 << static_cast<Byte>(event.direction))) && (entry->visibility & (1 << static_cast<Byte>(event.visibility)))) {
        result.enabled = true;
        result.fail_closed |= entry->route.fail_closed;
      }
    }
    return result;
  }

  inline void configure(Owner owner, InterceptionRule rule, std::uint64_t order = UINT64_MAX) {
    std::scoped_lock lock{mutex_};
    if (owner == 0 || registration(owner)) {
      throw EncodingError{"Interception owner already registered"};
    }

    for (auto &slot : registrations_) {
      if (!slot) {
        slot.emplace(upstream_, owner, rule, ++generation_, order);
        active_.fetch_add(1, std::memory_order_release);
        return;
      }
    }

    throw EncodingError{"Interception registration limit reached"};
  }

  inline void disconnect(Owner owner = default_owner) noexcept {
    std::scoped_lock lock{mutex_};
    for (auto &slot : registrations_) {
      if (slot && slot->route.owner == owner) {
        slot.reset();
        active_.fetch_sub(1, std::memory_order_release);
      }
    }

    for (auto &slot : pending_) {
      if (slot && slot->verdict == Verdict::pending && slot->chain[slot->step].owner == owner) {
        advance(*slot, failure(*slot));
      }
    }
  }

  inline void setAvailable(Owner owner, bool available) noexcept {
    std::scoped_lock lock{mutex_};
    auto *entry = registration(owner);
    if (!entry || (!available && !entry->available)) { return; }
    entry->available = false;
    for (auto &pending : pending_) {
      if (pending && pending->verdict == Verdict::pending && pending->chain[pending->step].owner == owner) { advance(*pending, failure(*pending)); }
    }
    if (available) {
      entry->route.generation = ++generation_;
      entry->available = true;
    }
  }

  inline bool pending(Owner owner, std::uint64_t ticket) noexcept {
    std::scoped_lock lock{mutex_};
    const auto *entry = registration(owner);
    if (!entry || !entry->available) { return false; }
    for (const auto &pending : pending_) {
      if (pending && pending->verdict == Verdict::pending && pending->decision_ticket == ticket && pending->chain[pending->step].owner == owner && pending->chain[pending->step].generation == entry->route.generation && std::chrono::steady_clock::now() < pending->deadline) { return true; }
    }
    return false;
  }

  inline auto begin(const FlowEvent &event) noexcept -> std::uint64_t {
    if (active_.load(std::memory_order_acquire) == 0) {
      return 0;
    }

    std::scoped_lock lock{mutex_};
    std::array<Route, Limits::subscribers> matches;
    std::size_t count = 0;
    bool fail_closed = false;
    for (const auto &entry : registrations_) {
      if (entry && entry->hosts.contains(event.host) && (entry->directions & (1 << static_cast<Byte>(event.direction))) && (entry->visibility & (1 << static_cast<Byte>(event.visibility)))) {
        if (!entry->available) {
          if (entry->route.fail_closed) { return rejected_ticket; }
          continue;
        }
        matches[count++] = entry->route;
        fail_closed |= entry->route.fail_closed;
      }
    }

    if (count == 0) {
      return 0;
    }

    std::ranges::sort(std::span{matches}.first(count), [](const auto &left, const auto &right) {
      return left.order < right.order || (left.order == right.order && left.generation < right.generation);
    });
    for (auto &slot : pending_) {
      if (!slot) {
        try {
          if (event.bytes.size() > maximum_bytes) {
            return fail_closed ? rejected_ticket : 0;
          }

          slot.emplace(memory_, ++next_, event, std::span{matches}.first(count));
          slot->deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{matches[0].timeout_ms};
          request_signal_.notify();
          return slot->ticket;
        } catch (...) {
          slot.reset();
          return fail_closed ? rejected_ticket : 0;
        }
      }
    }

    return fail_closed ? rejected_ticket : 0;
  }

  inline void decide(std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes) {
    decide(default_owner, ticket, verdict, bytes);
  }

  inline void decide(Owner owner, std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes) {
    if (verdict == Verdict::pending || bytes.size() > maximum_bytes || (verdict != Verdict::replace && !bytes.empty())) {
      throw EncodingError{"Invalid stream decision"};
    }

    std::scoped_lock lock{mutex_};
    for (auto &slot : pending_) {
      if (slot && slot->decision_ticket == ticket && slot->verdict == Verdict::pending && slot->chain[slot->step].owner == owner) {
        if (std::chrono::steady_clock::now() >= slot->deadline) {
          advance(*slot, failure(*slot));
          return;
        }

        if (verdict == Verdict::replace) {
          slot->bytes.assign(bytes.begin(), bytes.end());
          slot->replaced = true;
        }

        advance(*slot, verdict);
        return;
      }
    }
    // Late responses are harmless and must never apply to a different chunk.
  }

  inline auto poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept -> FlowControl::Decision {
    if (ticket == rejected_ticket) {
      return {.verdict = Verdict::reject};
    }

    std::scoped_lock lock{mutex_};
    for (auto &slot : pending_) {
      if (slot && slot->ticket == ticket) {
        if (slot->verdict == Verdict::pending && std::chrono::steady_clock::now() >= slot->deadline) {
          advance(*slot, failure(*slot));
        }
        const auto verdict = slot->verdict;
        if (verdict == Verdict::pending) {
          return {verdict};
        }
        const auto count = verdict == Verdict::replace ? slot->bytes.size() : 0;
        if (count > replacement.size()) {
          slot.reset();
          return {.verdict = Verdict::reject};
        }
        if (count != 0) {
          std::ranges::copy(slot->bytes, replacement.begin());
        }
        slot.reset();
        return {verdict, count};
      }
    }
    return {.verdict = Verdict::reject};
  }

  inline auto pending(std::uint64_t ticket) noexcept -> bool {
    std::scoped_lock lock{mutex_};
    for (const auto &slot : pending_) {
      if (slot && slot->ticket == ticket) {
        return slot->verdict == Verdict::pending && std::chrono::steady_clock::now() < slot->deadline;
      }
    }

    return false;
  }

  // The service queues requests on its own thread, without a lossy cross-thread channel.
  template <typename Consumer>
  inline void deliver(Owner owner, Consumer &&consumer) noexcept {
    std::scoped_lock lock{mutex_};
    for (auto &slot : pending_) {
      if (!slot || slot->verdict != Verdict::pending || slot->chain[slot->step].owner != owner || slot->delivered) {
        continue;
      }

      if (std::chrono::steady_clock::now() >= slot->deadline) {
        advance(*slot, failure(*slot));
        continue;
      }

      try {
        if (consumer(slot->event())) {
          slot->delivered = true;
        } else {
          advance(*slot, failure(*slot));
        }
      } catch (...) {
        advance(*slot, failure(*slot));
      }
    }
  }

  inline int requestDescriptor() const noexcept { return request_signal_.descriptor(); }
  inline void drainRequests() noexcept { request_signal_.drain(); }
  inline auto completionSignal() noexcept -> CompletionSignal & { return completion_; }
  inline auto requestSignal() noexcept -> CompletionSignal & { return request_signal_; }

  inline void cancel(std::uint64_t ticket) noexcept {
    std::scoped_lock lock{mutex_};

    for (auto &slot : pending_) {
      if (slot && slot->ticket == ticket) {
        slot.reset();
        return;
      }
    }
  }

  inline std::optional<FlowControl::Time> deadline(std::uint64_t ticket) noexcept {
    std::lock_guard lock{mutex_};
    for (const auto &slot : pending_) {
      if (slot && slot->ticket == ticket) {
        return slot->deadline;
      }
    }
    return std::chrono::steady_clock::now();
  }

  inline int descriptor() const noexcept {
    return completion_.descriptor();
  }

  inline void drain() noexcept {
    completion_.drain();
  }

  static constexpr std::uint64_t rejected_ticket = UINT64_MAX;

private:
  inline auto registration(Owner owner) noexcept -> Registration * {
    for (auto &slot : registrations_) {
      if (slot && slot->route.owner == owner) {
        return &*slot;
      }
    }

    return nullptr;
  }

  inline static Verdict failure(const Pending &pending) noexcept {
    return pending.chain[pending.step].fail_closed ? Verdict::reject : Verdict::allow;
  }

  inline void advance(Pending &pending, Verdict verdict) noexcept {
    for (;;) {
      if (verdict == Verdict::reject || ++pending.step == pending.routes) {
        pending.verdict = verdict == Verdict::reject ? Verdict::reject : pending.replaced ? Verdict::replace : Verdict::allow;
        completion_.notify();
        return;
      }

      const auto &route = pending.chain[pending.step];
      const auto *entry = registration(route.owner);
      if (entry && entry->available && entry->route.generation == route.generation) {
        pending.decision_ticket = ++next_;
        pending.deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{route.timeout_ms};
        pending.delivered = false;
        request_signal_.notify();
        completion_.notify();
        return;
      }

      verdict = failure(pending);
    }
  }

  static constexpr Owner default_owner = 1;
  Memory &upstream_;
  Secure memory_;
  std::mutex mutex_;
  std::array<std::optional<Registration>, Limits::subscribers> registrations_;
  std::array<std::optional<Pending>, 64> pending_;
  CompletionSignal wake_;
  CompletionSignal requests_;
  CompletionSignal &completion_;
  CompletionSignal &request_signal_;
  std::uint64_t generation_ = 0;
  std::uint64_t next_ = 0;
  std::atomic<std::size_t> active_{0};
};

}
}

// Interface: traffic/package_port.cppm
export {
namespace telar::runtime::traffic {

struct PackageChannel {
  FileDescriptor socket;
  std::uint64_t owner;
  inline int get() const noexcept { return socket.get(); }
};

// Only native runtime code can attach a package. Lua never supplies this grant
// or opens the authenticated endpoint; each registration gets its own channel.
class PackagePort {
public:
  virtual ~PackagePort() = default;
  virtual PackageChannel openPackage(const plugins::ServiceSpec &specification, std::uint32_t registration = 0) = 0;
  virtual void setPackageAvailable(std::uint64_t owner, bool available) noexcept = 0;
  virtual bool packagePending(std::uint64_t owner, std::uint64_t ticket, bool http) noexcept = 0;
  inline virtual void packageFailure(const plugins::ServiceSpec &, FlowEvent) noexcept {}
  inline virtual FileDescriptor openControl(const plugins::ServiceSpec &) { throw SystemError{"Package control is not available", EAGAIN}; }
  inline virtual void revokePackage(const plugins::ServiceSpec &) noexcept {}
};

}
}

// Interface: traffic/recording_owner.cppm
export {
namespace telar::runtime::traffic::recording {

struct Owner {
  std::uint64_t id = 0;
  plugins::PackageDigest digest{};
  std::shared_ptr<std::atomic<bool>> permission;

  inline static Owner package(const plugins::ServiceSpec &package) { return {package.plugin_id, package.digest, package.permission}; }
  inline bool authorized() const noexcept { return !permission || permission->load(std::memory_order_acquire); }
  inline bool matches(const Owner &other) const noexcept { return id == other.id && digest == other.digest; }
  inline bool canRead(const Owner &other) const noexcept { return id == 0 || matches(other); }
};

}
}

// Interface: traffic/recordings.cppm
export {
namespace telar::runtime::traffic {

template <ConcurrentAllocator Memory, typename Clock = std::chrono::steady_clock>
class Recordings {
  using Request = recording::Request;
  struct Entry {
    std::uint64_t cursor;
    typename Clock::time_point created;
    std::shared_ptr<EventFrame<Memory>> frame;
  };

  struct Session {
    inline explicit Session(Memory &memory, const Request &request, std::uint64_t id, recording::Owner owner)
        : id(id), owner(std::move(owner)), budget(request.max_bytes), age(request.max_age_ms), selection(request.selection), filter(request.filter), host(memory), entries(AllocatorRef<std::optional<Entry>, Memory>{memory}) {
      if (!request.host.empty() && !host.append(request.host)) { throw EncodingError{"Invalid recording host scope"}; }
      host.finish();
      entries.resize(request.max_events);
      bytes = entries.capacity() * sizeof(std::optional<Entry>);
      if (bytes >= budget) { throw EncodingError{"Recording budget cannot hold its event index"}; }
    }

    inline Entry &at(std::size_t index) { return *entries[(head + index) % entries.size()]; }
    inline void evict() noexcept {
      bytes -= at(0).frame->bytes.bytes().size();
      entries[head].reset();
      head = (head + 1) % entries.size();
      --count;
      ++evicted;
    }
    inline void expire(typename Clock::time_point now) noexcept {
      while (count != 0 && now - at(0).created >= age) { evict(); }
    }

    std::uint64_t id;
    recording::Owner owner;
    std::size_t budget;
    std::chrono::milliseconds age;
    Selection selection;
    Filter filter;
    ProxyHostPolicy<Memory> host;
    Vector<std::optional<Entry>, Memory> entries;
    std::size_t bytes = 0;
    std::size_t head = 0;
    std::size_t count = 0;
    std::uint64_t next = 1;
    std::uint64_t evicted = 0;
    std::uint64_t dropped = 0;
    bool active = true;
  };

public:
  inline explicit Recordings(Memory &memory) noexcept : memory_(memory) { randomBytes(&next_id_, sizeof(next_id_)); }

  inline bool selects(Selection selection) const noexcept { return (interest_.load(std::memory_order_acquire) & static_cast<Byte>(selection)) != 0; }

  inline std::shared_ptr<EventFrame<Memory>> record(const Event &event, std::shared_ptr<EventFrame<Memory>> shared = {}) noexcept {
    if (!selected(Selection::all, event.kind) || interest_.load(std::memory_order_acquire) == 0) { return shared; }
    const std::unique_lock lock{mutex_, std::try_to_lock};
    if (!lock.owns_lock()) { contention_drops_.fetch_add(1, std::memory_order_relaxed); return shared; }
    const auto now = Clock::now();
    for (auto &slot : sessions_) {
      if (!slot || !slot->active || !slot->owner.authorized() || !selected(slot->selection, event.kind)) { continue; }
      auto &session = *slot;
      session.expire(now);
      try {
        if (!session.filter.matches(event) || !matches(session.host, event)) { continue; }
        const auto size = Protocol::encodedSize(event);
        const auto index_bytes = session.entries.capacity() * sizeof(std::optional<Entry>);
        if (size > session.budget - index_bytes || session.next == UINT64_MAX) { ++session.dropped; continue; }
        while (session.count != 0 && (session.count == session.entries.size() || size > session.budget - session.bytes)) { session.evict(); }
        if (!shared) {
          shared = std::allocate_shared<EventFrame<Memory>>(AllocatorRef<EventFrame<Memory>, Memory>{memory_}, memory_, size);
          Protocol::encode(shared->bytes.bytes(), event);
        }
        session.entries[(session.head + session.count) % session.entries.size()].emplace(Entry{session.next++, now, shared});
        ++session.count;
        session.bytes += size;
      } catch (...) { ++session.dropped; }
    }
    return shared;
  }

  inline void expire() noexcept {
    const std::unique_lock lock{mutex_, std::try_to_lock};
    if (!lock.owns_lock()) { return; }
    for (auto &session : sessions_) { if (session) { session->expire(Clock::now()); } }
  }

  inline void revoke(const recording::Owner &owner) noexcept {
    const std::lock_guard lock{mutex_};
    for (auto &session : sessions_) { if (session && owner.matches(session->owner)) { session->active = false; } }
    refreshInterest();
  }

  inline std::span<const Byte> handle(const Request &request, std::span<Byte> output, recording::Owner owner = {}) {
    if (output.size() < recording::Protocol::page_header_bytes) { throw EncodingError{"Recording output is too small"}; }
    std::array<Byte, 8192> validation;
    plugins::FrameWriter validated{validation};
    recording::Protocol::write(validated, request);
    ProxyHostPolicy scope{memory_};
    if (!request.host.empty() && !scope.append(request.host)) { throw EncodingError{"Invalid recording query host"}; }
    scope.finish();
    const std::lock_guard lock{mutex_};
    if (!owner.authorized()) { throw EncodingError{"Recording package permission has been revoked"}; }
    if (request.operation == recording::Operation::list) {
      output = output.first(std::min(output.size(), recording::Limits::page_bytes));
      plugins::FrameWriter rows{output.subspan(recording::Protocol::page_header_bytes)};
      recording::Page page{.format = recording::Format::list};
      for (auto &slot : sessions_) {
        if (!slot || !owner.canRead(slot->owner)) { continue; }
        slot->expire(Clock::now());
        std::array<Byte, recording::Protocol::page_header_bytes> bytes;
        plugins::FrameWriter child{bytes};
        recording::Protocol::header(child, describe(*slot));
        rows.bytes(child.finish());
        ++page.count;
      }
      plugins::FrameWriter header{output.first(recording::Protocol::page_header_bytes)};
      recording::Protocol::header(header, page);
      return output.first(header.finish().size() + rows.finish().size());
    }
    Session *session = nullptr;
    if (request.operation == recording::Operation::start) {
      std::uint64_t reserved = request.max_bytes;
      for (const auto &existing : sessions_) { if (existing) { reserved += existing->budget; } }
      if (reserved > recording::Limits::total_bytes) { throw EncodingError{"Recording runtime budget exhausted"}; }
      for (auto &slot : sessions_) {
        if (slot) { continue; }
        if (++next_id_ == 0) { ++next_id_; }
        slot.emplace(memory_, request, next_id_, owner);
        session = &*slot;
        break;
      }
      if (!session) { throw EncodingError{"Recording session limit reached"}; }
      refreshInterest();
    } else {
      for (auto &slot : sessions_) { if (slot && slot->id == request.id && owner.canRead(slot->owner)) { session = &*slot; break; } }
      if (!session) { throw EncodingError{"Unknown or expired recording identity"}; }
    }
    session->expire(Clock::now());
    if (request.operation == recording::Operation::stop) { session->active = false; refreshInterest(); }
    auto page = describe(*session);
    output = output.first(std::min(output.size(), recording::Limits::page_bytes));
    if (output.size() < recording::Protocol::page_header_bytes) { throw EncodingError{"Recording output is too small"}; }
    plugins::FrameWriter rows{output.subspan(recording::Protocol::page_header_bytes)};
    if (request.operation == recording::Operation::query || request.operation == recording::Operation::pcapng) {
      if (request.cursor > session->next) { throw EncodingError{"Recording cursor is beyond the current end"}; }
      page.gap = request.cursor != 0 && request.cursor < page.oldest;
      page.next = request.cursor == 0 ? page.oldest : std::max(request.cursor, page.oldest);
      const bool pcapng = request.operation == recording::Operation::pcapng;
      page.format = pcapng ? recording::Format::pcapng : recording::Format::events;
      if (pcapng) { Pcapng::section(rows); }
      for (std::size_t index = 0; index < session->count; ++index) {
        auto &entry = session->at(index);
        if (entry.cursor < page.next) { continue; }
        const auto event = Protocol::decode(entry.frame->bytes.bytes());
        if (!selected(request.selection, event.kind) || !matches(scope, event) || (pcapng && event.kind != Kind::packet)) { page.next = entry.cursor + 1; continue; }
        const auto size = pcapng ? Pcapng::packetBytes(event) : sizeof(std::uint64_t) + sizeof(std::uint32_t) + entry.frame->bytes.bytes().size();
        if (size > output.size() - recording::Protocol::page_header_bytes - rows.finish().size() || page.count == request.limit) { break; }
        if (pcapng) { Pcapng::packet(rows, event, page.count); }
        else { rows.integer(entry.cursor); rows.bytes(entry.frame->bytes.bytes()); }
        ++page.count;
        page.next = entry.cursor + 1;
      }
    }
    if (request.operation == recording::Operation::erase) {
      page.active = false;
      page.bytes = 0;
      for (auto &slot : sessions_) { if (slot && &*slot == session) { slot.reset(); break; } }
      refreshInterest();
    }
    plugins::FrameWriter header{output.first(recording::Protocol::page_header_bytes)};
    recording::Protocol::header(header, page);
    return output.first(header.finish().size() + rows.finish().size());
  }

private:
  inline recording::Page describe(Session &session) const noexcept {
    return {
        .id = session.id, .active = session.active, .oldest = session.count ? session.at(0).cursor : session.next,
        .next = session.next, .end = session.next, .evicted = session.evicted, .dropped = session.dropped,
        .contention_drops = contention_drops_.load(std::memory_order_relaxed), .bytes = session.bytes,
    };
  }

  inline static bool selected(Selection selection, Kind kind) noexcept {
    const auto mask = static_cast<Byte>(selection);
    const auto bit = kind == Kind::packet ? Selection::packets : kind == Kind::exchange ? Selection::exchanges : kind == Kind::datagram ? Selection::datagrams : Selection::flows;
    const bool public_event = kind == Kind::packet || kind == Kind::exchange || kind == Kind::datagram || (kind >= Kind::flow_open && kind <= Kind::flow_gap);
    return public_event && (mask & static_cast<Byte>(bit)) != 0;
  }

  inline static bool matches(const ProxyHostPolicy<Memory> &scope, const Event &event) {
    if (scope.patterns().empty()) { return true; }
    if (event.kind == Kind::exchange) { return scope.contains(plugins::Protocol::decodeExchange(event.bytes).host); }
    if (event.kind >= Kind::flow_open && event.kind <= Kind::flow_gap) { return scope.contains(FlowCodec::decode(event.bytes).host); }
    return false;
  }

  inline void refreshInterest() noexcept {
    Byte mask = 0;
    for (const auto &session : sessions_) { if (session && session->active) { mask |= static_cast<Byte>(session->selection); } }
    interest_.store(mask, std::memory_order_release);
  }

  Memory &memory_;
  std::array<std::optional<Session>, recording::Limits::sessions> sessions_;
  std::uint64_t next_id_;
  std::mutex mutex_;
  std::atomic<Byte> interest_{0};
  std::atomic<std::uint64_t> contention_drops_{0};
};

}
}

// Interface: traffic/service.cppm
export {
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
    inline explicit Peer(SensitiveMemory &memory, FileDescriptor socket, uid_t uid)
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
  inline explicit Service(Memory &memory, std::string_view path, bool allow_interception = false) : upstream_(memory), memory_(memory), listener_(path), interception_(memory), http_interception_(memory, &interception_.completionSignal(), &interception_.requestSignal()), analysis_(memory), recordings_(memory), allow_interception_(allow_interception) {
    randomBytes(&session_, sizeof(session_));
    const auto error = ::pthread_create(&thread_, nullptr, &start, this);
    if (error != 0) {
      throw SystemError{"Start traffic service", error};
    }
  }

  inline ~Service() {
    stopping_.store(true, std::memory_order_release);
    wake_.notify();
    ::pthread_join(thread_, nullptr);
  }

  Service(const Service &) = delete;
  Service &operator=(const Service &) = delete;

  inline bool listening() const noexcept { return exchange_subscribers_.load(std::memory_order_acquire) != 0 || recordings_.selects(Selection::exchanges); }

  inline std::span<const Byte> recording(const recording::Request &request, std::span<Byte> output, recording::Owner owner = {}) { return recordings_.handle(request, output, std::move(owner)); }

  inline void packageControl(control::PackagePort *port) noexcept { package_control_.store(port, std::memory_order_release); }

  inline FileDescriptor openControl(const plugins::ServiceSpec &package) override {
    const auto port = package_control_.load(std::memory_order_acquire);
    if (!port) { throw SystemError{"Package control is starting", EAGAIN}; }
    return port->openPackage(package);
  }

  inline void revokePackage(const plugins::ServiceSpec &package) noexcept override { recordings_.revoke(recording::Owner::package(package)); }

  inline PackageChannel openPackage(const plugins::ServiceSpec &specification, std::uint32_t registration = 0) override {
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

  inline void setPackageAvailable(std::uint64_t owner, bool available) noexcept override {
    interception_.setAvailable(owner, available);
    http_interception_.setAvailable(owner, available);
  }

  inline bool packagePending(std::uint64_t owner, std::uint64_t ticket, bool http) noexcept override {
    return http ? http_interception_.pending(owner, ticket) : interception_.pending(owner, ticket);
  }

  inline void packageFailure(const plugins::ServiceSpec &specification, FlowEvent event) noexcept override {
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

  inline CaptureStatus captureStatus() const noexcept {
    std::lock_guard lock{capture_mutex_};
    return capture_status_;
  }

  inline std::uint64_t stopCapture() noexcept {
    const auto revision = capture_stop_.fetch_add(1, std::memory_order_release) + 1;
    wake_.notify();
    return revision;
  }

  inline bool captureStopped(std::uint64_t revision) const noexcept { return capture_stopped_.load(std::memory_order_acquire) >= revision; }

  inline void submit(CapturedExchange<Memory> &exchange) noexcept {
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

  inline void observeFlow(Kind kind, const FlowEvent &flow) noexcept override {
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

  inline std::uint64_t intercept(const FlowEvent &event) noexcept override {
    return interception_.begin(event);
  }

  inline Decision poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept override { return interception_.poll(ticket, replacement); }
  inline void cancel(std::uint64_t ticket) noexcept override { interception_.cancel(ticket); }
  inline std::optional<Time> deadline(std::uint64_t ticket) noexcept override { return interception_.deadline(ticket); }
  inline int descriptor() const noexcept override { return interception_.descriptor(); }
  inline void drain() noexcept override { interception_.drain(); }
  inline HttpControl *http() noexcept override { return allow_interception_ ? this : nullptr; }
  inline HttpPolicy policy(const FlowEvent &context) noexcept override { return http_interception_.policy(context); }
  inline std::uint64_t interceptHttp(const FlowEvent &event) noexcept override { return http_interception_.begin(event); }
  inline Decision pollHttp(std::uint64_t ticket, std::span<Byte> replacement) noexcept override { return http_interception_.poll(ticket, replacement); }
  inline void cancelHttp(std::uint64_t ticket) noexcept override { http_interception_.cancel(ticket); }
  inline std::optional<Time> httpDeadline(std::uint64_t ticket) noexcept override { return http_interception_.deadline(ticket); }
  inline void httpUnavailable(const FlowEvent &event) noexcept override { observeFlow(Kind::flow_error, event); }

private:
  inline static void *start(void *context) noexcept {
    static_cast<Service *>(context)->run();
    return nullptr;
  }

  inline void run() noexcept {
    while (!stopping_.load(std::memory_order_acquire)) {
      try {
        step();
      } catch (const std::exception &error) {
        std::fprintf(stderr, "telar traffic: %s\n", error.what());
      }
    }
  }

  inline void step() {
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

  inline void accept() {
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

  inline void read(Peer &peer) {
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

  inline bool greet(Peer &peer) {
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

  inline void control(Peer &peer) {
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

  inline std::shared_ptr<Frame> encode(const Event &event) {
    auto frame = std::allocate_shared<Frame>(AllocatorRef<Frame, SensitiveMemory>{memory_}, upstream_, Protocol::encodedSize(event));
    Protocol::encode(frame->bytes.bytes(), event);
    return frame;
  }

  inline void publish(const Event &event, std::shared_ptr<Frame> shared = {}) {
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

  inline static void enqueue(Peer &peer, std::shared_ptr<Frame> frame) {
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

  inline static void write(Peer &peer) {
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
}

// Interface: traffic/control_backend.cppm
export {
namespace telar::runtime::traffic::control {

template <Allocator Memory>
class TrustCommand {
public:
  inline explicit TrustCommand(Memory &memory, const std::atomic<bool> &cancelled) noexcept : memory_(memory), cancelled_(cancelled) {}

  inline void run(std::span<const std::string_view> arguments) {
    bool allowed = !arguments.empty() && arguments.front() == "/usr/bin/security";
#if defined(__linux__)
    constexpr std::array executables{"/usr/bin/trust", "/usr/bin/install", "/usr/bin/rm", "/usr/sbin/update-ca-certificates"};
    allowed = arguments.size() >= 3 && arguments[0] == "/usr/bin/sudo" && arguments[1] == "--" && std::ranges::find(executables, arguments[2]) != executables.end();
#endif
    if (!allowed) { throw std::invalid_argument{"Invalid trust operation"}; }
    Command command{memory_, Launch{.arguments = arguments}, CommandPurpose::administration};
    CommandOutput output{memory_, Limits::reply_bytes, &cancelled_};
    if (output.run(command, std::chrono::steady_clock::now() + std::chrono::seconds{10}, true) != 0) { throw SystemError{"Certificate store operation failed", EACCES}; }
  }

private:
  Memory &memory_;
  const std::atomic<bool> &cancelled_;
};

struct Configuration {
  std::string_view endpoint;
  std::string_view executable;
  bool proxy = false;
  bool redirect = false;
  bool transparent_tls = false;
  bool interception = false;
  bool administration = false;
};

template <ConcurrentAllocator Memory, typename Proxy>
class Backend {
  using Clock = std::chrono::steady_clock;
public:
  inline explicit Backend(Memory &memory, Proxy &proxy, traffic::Service<Memory> *capture, Configuration configuration)
      : memory_(memory), proxy_(proxy), capture_(capture), configuration_(configuration) {}

  inline ~Backend() {
    capture_cancelled_ = true;
    redirect_cancelled_ = true;
    if (capture_child_ > 0 && capture_) { capture_->stopCapture(); }
    if (redirect_child_ > 0) { proxy_.stopRedirect(); }
    const auto deadline = Clock::now() + std::chrono::seconds{5};
    while ((capture_child_ > 0 || redirect_child_ > 0) && Clock::now() < deadline) {
      tick();
      ::poll(nullptr, 0, 5);
    }
  }

  inline void tick() noexcept {
    reap(capture_child_);
    reap(redirect_child_);
    if (capture_cancelled_ && capture_child_ > 0 && capture_ && capture_->captureStatus().state != traffic::Service<Memory>::CaptureState::idle) { capture_->stopCapture(); }
    if (redirect_cancelled_ && redirect_child_ > 0) {
      const auto state = proxy_.redirectStatus();
      if (state == redirect::MonitorState::starting || state == redirect::MonitorState::active) { proxy_.stopRedirect(); }
    }
  }

  inline std::span<const Byte> handle(const Request &request, std::span<Byte> output, const std::atomic<bool> &cancelled, const plugins::ServiceSpec *package = nullptr) {
    Reply reply;
    std::optional<SensitiveAllocation<Memory>> recording_output;
    std::array<char, 1025> error{};
    try {
      if (package && !authorized(*package, request)) {
        reply.result = Result::disabled;
        reply.message = "Package traffic capability denied or revoked";
      } else if (request.operation != Operation::status && request.operation != Operation::ca_certificate && request.operation != Operation::recording && !configuration_.administration) {
        reply.result = Result::disabled;
        reply.message = "Runtime proxy.network_control permission is disabled";
      } else switch (request.operation) {
      case Operation::status:
      case Operation::ca_certificate:
        break;
      case Operation::capture_start:
      case Operation::redirect_start:
        start(request, reply, cancelled);
        break;
      case Operation::capture_stop:
        if (!capture_) { reply.result = Result::disabled; }
        else {
          capture_cancelled_ = true;
          const auto revision = capture_->stopCapture();
          if (!wait([&] { return capture_->captureStopped(revision) && capture_child_ <= 0; }, cancelled)) { reply.result = Result::busy; reply.message = "Capture is stopping"; }
        }
        break;
      case Operation::redirect_stop:
        if (!configuration_.redirect) { reply.result = Result::disabled; }
        else {
          redirect_cancelled_ = true;
          proxy_.stopRedirect();
          if (!wait([&] { const auto state = proxy_.redirectStatus(); return redirect_child_ <= 0 && (state == redirect::MonitorState::idle || state == redirect::MonitorState::cleanup_required); }, cancelled)) {
            reply.result = Result::busy;
            reply.message = "Redirect cleanup is still running";
          } else if (proxy_.redirectStatus() == redirect::MonitorState::cleanup_required) {
            reply.result = Result::cleanup_required;
            reply.message = "The helper disconnected without confirming PF cleanup";
            authorization(request, reply, "redirect-cleanup");
          }
        }
        break;
      case Operation::ca_install:
      case Operation::ca_uninstall:
      case Operation::ca_rotate:
        if (!configuration_.proxy) { reply.result = Result::disabled; }
        else {
          TrustCommand command{memory_, cancelled};
          proxy_.manageAuthority(request.operation == Operation::ca_install ? proxy_trust::Action::install : request.operation == Operation::ca_uninstall ? proxy_trust::Action::uninstall : proxy_trust::Action::rotate, command);
        }
        break;
      case Operation::recording:
        if (!capture_) { reply.result = Result::disabled; }
        else {
          recording_output.emplace(memory_, recording::Limits::page_bytes);
          reply.recording = capture_->recording(*request.recording, recording_output->bytes(), package ? recording::Owner::package(*package) : recording::Owner{});
        }
        break;
      }
    } catch (const std::exception &failure) {
      reply.result = Result::failed;
      const auto message = std::string_view{failure.what()}.substr(0, error.size() - 1);
      std::ranges::copy(message, error.begin());
      reply.message = {error.data(), message.size()};
    }

    reply.status = status();
    if (package && !package->allows(plugins::Capability::traffic_control)) { reply.status.administration = false; }
    const auto authority = proxy_.authorityStatus(request.operation == Operation::ca_certificate);
    reply.status.tls_accepting = authority.accepting;
    reply.status.trust = static_cast<TrustState>(authority.trust);
    if (authority.active) {
      reply.fingerprint_sha1 = {authority.fingerprint_sha1.data(), authority.fingerprint_sha1.size()};
      reply.fingerprint_sha256 = {authority.fingerprint_sha256.data(), authority.fingerprint_sha256.size()};
      reply.certificate = std::span{authority.certificate}.first(authority.certificate_bytes);
    } else if (request.operation == Operation::ca_certificate) { reply.result = Result::disabled; }
    return Protocol::encode(output, reply);
  }

private:
  inline Status status() const noexcept {
    Status status{.proxy = configuration_.proxy, .transparent_tls = configuration_.transparent_tls, .interception = configuration_.interception, .administration = configuration_.administration};
    const auto proxy = proxy_.clientConfiguration().status();
    status.port = proxy.port.value_or(0);
    if (capture_) {
      const auto capture = capture_->captureStatus();
      switch (capture.state) {
      case traffic::Service<Memory>::CaptureState::idle: status.capture = CaptureState::idle; break;
      case traffic::Service<Memory>::CaptureState::live: status.capture = CaptureState::live; break;
      case traffic::Service<Memory>::CaptureState::offline: status.capture = CaptureState::offline; break;
      }
      status.capture_session = capture.session;
      status.interfaces = capture.interfaces;
      status.interface_errors = capture.interface_errors;
    }
    if (configuration_.redirect) {
      switch (proxy_.redirectStatus()) {
      case redirect::MonitorState::idle: status.redirect = RedirectState::idle; break;
      case redirect::MonitorState::starting: status.redirect = RedirectState::starting; break;
      case redirect::MonitorState::active: status.redirect = RedirectState::active; break;
      case redirect::MonitorState::stopping: status.redirect = RedirectState::stopping; break;
      case redirect::MonitorState::cleanup_required: status.redirect = RedirectState::cleanup_required; break;
      }
    }
    return status;
  }

  inline void authorization(const Request &request, Reply &reply, std::string_view action) const {
    reply.authorization[0] = "/usr/bin/sudo";
    reply.authorization[1] = "--";
    reply.authorization[2] = configuration_.executable;
    reply.authorization[3] = "traffic";
    reply.authorization[4] = action;
    reply.authorization[5] = "--socket";
    reply.authorization[6] = configuration_.endpoint;
    reply.argument_count = 7;
    if (action == "redirect") {
      for (std::size_t index = 0; index < selection_->targets().size(); ++index) {
        reply.authorization[reply.argument_count++] = "--target";
        reply.authorization[reply.argument_count++] = selection_->argument(index);
      }
      for (std::size_t index = 0; index < request.process_count; ++index) {
        reply.authorization[reply.argument_count++] = "--process";
        reply.authorization[reply.argument_count++] = process_arguments_[index].view();
      }
      if (request.direction != redirect::Direction::outbound) {
        reply.authorization[reply.argument_count++] = "--direction";
        reply.authorization[reply.argument_count++] = redirect::directionName(request.direction);
      }
    }
  }

  inline void start(const Request &request, Reply &reply, const std::atomic<bool> &cancelled) {
    const bool capture = request.operation == Operation::capture_start;
    if (capture ? capture_ == nullptr : !configuration_.redirect) { reply.result = Result::disabled; return; }
    if (capture && capture_->captureStatus().state == traffic::Service<Memory>::CaptureState::live) { return; }
    if ((capture && capture_->captureStatus().state == traffic::Service<Memory>::CaptureState::offline) || (!capture && proxy_.redirectStatus() != redirect::MonitorState::idle && proxy_.redirectStatus() != redirect::MonitorState::cleanup_required)) {
      reply.result = Result::busy;
      reply.message = "An existing helper must stop before its selection changes";
      return;
    }
    if (!capture) {
      const ProcessInspector inspector;
      for (std::size_t index = 0; index < request.process_count; ++index) {
        const auto process = inspector.identity(static_cast<pid_t>(request.processes[index]));
        if (!process) { throw std::invalid_argument{"Selected process must be running under the runtime account"}; }
        process_arguments_[index] = redirect::ProcessToken::format(*process);
      }
      selection_.emplace(std::span{request.targets}.first(request.target_count), cancelled, Clock::now() + std::chrono::seconds{3});
      redirect::LocalAddresses::selection(selection_->targets(), request.direction);
    }
    auto &child = capture ? capture_child_ : redirect_child_;
    tick();
    if (child > 0) { reply.result = Result::busy; reply.message = "The previous helper is still stopping"; return; }
    (capture ? capture_cancelled_ : redirect_cancelled_) = false;
    authorization(request, reply, capture ? "capture" : "redirect");
    std::array<std::string_view, Limits::arguments> arguments;
    arguments[0] = "/usr/bin/sudo";
    arguments[1] = "-n";
    arguments[2] = "-l";
    std::ranges::copy(std::span{reply.authorization}.subspan(1, reply.argument_count - 1), arguments.begin() + 3);
    const auto count = reply.argument_count + 2;
    Command preflight{memory_, Launch{.arguments = std::span{arguments}.first(count)}, CommandPurpose::administration};
    CommandOutput result{memory_, Limits::reply_bytes, &cancelled};
    if (result.run(preflight, Clock::now() + std::chrono::seconds{3}, true) != 0) {
      reply.result = Result::authorization_required;
      reply.message = "Run authorization_argv in a terminal to authorize this native helper";
      return;
    }
    arguments[2] = "--";
    std::ranges::copy(std::span{reply.authorization}.subspan(2, reply.argument_count - 2), arguments.begin() + 3);
    Command command{memory_, Launch{.arguments = std::span{arguments}.first(count - 1)}, CommandPurpose::administration};
    const auto specification = command.specification({});
    SpawnOptions spawn{0};
    FileDescriptor input{::open("/dev/null", O_RDONLY | O_CLOEXEC)};
    if (!input) { throw SystemError{"Prepare privileged helper input"}; }
    spawn.redirect(input.get(), STDIN_FILENO);
    spawn.redirect(STDOUT_FILENO, STDOUT_FILENO);
    spawn.redirect(STDERR_FILENO, STDERR_FILENO);
    spawn.closeOthers();
    pid_t started;
    checkSpawn(::posix_spawn(&started, specification.executable, &spawn.actions, &spawn.attributes, specification.arguments, specification.environment));
    child = started;
    const auto ready = [&] { return capture ? capture_->captureStatus().state == traffic::Service<Memory>::CaptureState::live : proxy_.redirectStatus() == redirect::MonitorState::active; };
    wait([&] { return ready() || child <= 0; }, cancelled);
    if (!ready()) {
      reply.result = Result::failed;
      reply.message = "The privileged helper did not confirm activation; authorization_argv also provides its terminal diagnostics";
      (capture ? capture_cancelled_ : redirect_cancelled_) = true;
      if (capture) { capture_->stopCapture(); }
      if (!capture) { proxy_.stopRedirect(); }
      return;
    }
    reply.argument_count = 0;
  }

  template <typename Predicate>
  inline bool wait(Predicate predicate, const std::atomic<bool> &cancelled) {
    const auto deadline = Clock::now() + std::chrono::seconds{5};
    while (!predicate()) {
      if (cancelled.load(std::memory_order_acquire)) { throw std::runtime_error{"Network control is stopping"}; }
      if (Clock::now() >= deadline) { return false; }
      tick();
      ::poll(nullptr, 0, 5);
    }
    return true;
  }

  inline static void reap(pid_t &child) noexcept {
    if (child <= 0) { return; }
    int status;
    const auto waited = ::waitpid(child, &status, WNOHANG);
    if (waited == child || (waited < 0 && errno == ECHILD)) { child = -1; }
  }

  Memory &memory_;
  Proxy &proxy_;
  traffic::Service<Memory> *capture_;
  Configuration configuration_;
  static_assert(Limits::processes == redirect::SocketOwners::maximum_processes);
  static_assert(Limits::targets == redirect::Target::maximum_targets);
  std::optional<redirect::Selection<>> selection_;
  std::array<FixedText<redirect::ProcessToken::maximum_bytes>, Limits::processes> process_arguments_;
  pid_t capture_child_ = -1;
  pid_t redirect_child_ = -1;
  bool capture_cancelled_ = false;
  bool redirect_cancelled_ = false;
};

}
}

// Interface: traffic/control_service.cppm
export {
namespace telar::runtime::traffic::control {

// Administration has its own worker; certificate-store operations never run on
// the packet, proxy, or terminal workers. Each authenticated connection issues
// one bounded request. Closing a client only cancels delivery of its reply.
template <ConcurrentAllocator Memory, typename Handler>
class Service : public PackagePort {
  using Clock = std::chrono::steady_clock;
  struct Peer {
    inline explicit Peer(Memory &memory, FileDescriptor channel)
        : socket(std::move(channel)), input(memory, Limits::request_bytes + Protocol::prefix_bytes), output(memory, Limits::reply_bytes + Protocol::prefix_bytes) {}
    FileDescriptor socket;
    SensitiveAllocation<Memory> input;
    SensitiveAllocation<Memory> output;
    Clock::time_point deadline = Clock::now() + std::chrono::seconds{5};
    std::size_t expected = Protocol::prefix_bytes;
    std::size_t received = 0;
    std::size_t reply_bytes = 0;
    std::size_t sent = 0;
    std::optional<plugins::ServiceSpec> package;
  };

  struct Attachment {
    FileDescriptor socket;
    plugins::ServiceSpec package;
  };

public:
  inline explicit Service(Memory &memory, std::string_view path, Handler &handler)
      : memory_(memory), listener_(path), handler_(handler), worker_([this] { run(); }) {}

  inline ~Service() {
    stopping_.store(true, std::memory_order_release);
    wake_.notify();
    worker_.join();
  }

  Service(const Service &) = delete;
  Service &operator=(const Service &) = delete;

  inline FileDescriptor openPackage(const plugins::ServiceSpec &package) override {
    if (!package.traffic() || package.plugin_id == 0 || package.generation == 0) { throw SystemError{"Package control capability denied", EACCES}; }
    std::array<int, 2> descriptors;
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors.data()) != 0) { throw SystemError{"Create package control channel"}; }
    FileDescriptor native{descriptors[0]}, client{descriptors[1]};
    configureProxySocket(native.get());
    configureProxySocket(client.get());
    if (!attachments_.publish({std::move(native), package})) { throw SystemError{"Package control attachment queue is full", EBUSY}; }
    wake_.notify();
    return client;
  }

private:
  inline void run() noexcept {
    while (!stopping_.load(std::memory_order_acquire)) {
      try { step(); }
      catch (const std::exception &error) { std::fprintf(stderr, "telar network control: %s\n", error.what()); }
    }
  }

  inline void step() {
    std::array<pollfd, Limits::peers + 2> descriptors{};
    descriptors[0] = {.fd = listener_.descriptor(), .events = POLLIN, .revents = 0};
    descriptors[1] = {.fd = wake_.descriptor(), .events = POLLIN, .revents = 0};
    for (std::size_t index = 0; index < peers_.size(); ++index) {
      const auto &peer = peers_[index];
      descriptors[index + 2] = {.fd = peer ? peer->socket.get() : -1, .events = static_cast<short>(peer && peer->reply_bytes ? POLLOUT : POLLIN)};
    }
    if (::poll(descriptors.data(), descriptors.size(), 100) < 0 && errno != EINTR) { throw SystemError{"Poll network control"}; }
    if (stopping_.load(std::memory_order_acquire)) { return; }
    handler_.tick();

    if (descriptors[1].revents & POLLIN) {
      wake_.drain();
      while (auto attachment = attachments_.tryReceive()) {
        for (auto &peer : peers_) {
          if (!peer) { peer.emplace(memory_, std::move(attachment->socket)); peer->package = std::move(attachment->package); break; }
        }
      }
    }

    for (std::size_t index = 0; index < peers_.size(); ++index) {
      auto &peer = peers_[index];
      if (!peer) { continue; }
      const auto readiness = descriptors[index + 2].revents;
      bool close = (readiness & (POLLERR | POLLNVAL)) || Clock::now() >= peer->deadline;
      try {
        if (!close && (readiness & (POLLIN | POLLOUT | POLLHUP))) { close = advance(*peer); }
      } catch (const std::exception &) { close = true; }
      if (close) { peer.reset(); }
    }
    if (descriptors[0].revents & POLLIN) {
      auto socket = listener_.accept();
      if (!socket) { return; }
      for (auto &peer : peers_) {
        if (!peer) { peer.emplace(memory_, std::move(socket)); break; }
      }
    }
  }

  inline bool advance(Peer &peer) {
    if (peer.reply_bytes != 0) {
      const auto count = ::send(peer.socket.get(), peer.output.bytes().data() + peer.sent, peer.reply_bytes - peer.sent, 0);
      if (count < 0 && socketWouldBlock(errno)) { return false; }
      if (count <= 0) { return true; }
      peer.sent += static_cast<std::size_t>(count);
      return peer.sent == peer.reply_bytes;
    }
    for (std::size_t round = 0; round < 2; ++round) {
      const auto count = ::recv(peer.socket.get(), peer.input.bytes().data() + peer.received, peer.expected - peer.received, 0);
      if (count < 0 && socketWouldBlock(errno)) { return false; }
      if (count <= 0) { return true; }
      peer.received += static_cast<std::size_t>(count);
      if (peer.received != peer.expected) { return false; }
      if (peer.expected == Protocol::prefix_bytes) {
        plugins::FrameReader reader{peer.input.bytes().first(Protocol::prefix_bytes)};
        const auto length = reader.integer<std::uint32_t>();
        if (length == 0 || length > Limits::request_bytes) { return true; }
        peer.expected += length;
        continue;
      }
      const auto request = Protocol::request(peer.input.bytes().subspan(Protocol::prefix_bytes, peer.expected - Protocol::prefix_bytes));
      const auto output = peer.output.bytes().subspan(Protocol::prefix_bytes);
      std::span<const Byte> reply;
      try { reply = handler_.handle(request, output, stopping_, peer.package ? &*peer.package : nullptr); }
      catch (const std::exception &error) {
        reply = Protocol::encode(output, Reply{.result = Result::failed, .message = std::string_view{error.what()}.substr(0, 1024)});
      }
      const auto prefix = Protocol::prefix(reply.size());
      std::ranges::copy(prefix, peer.output.bytes().begin());
      peer.reply_bytes = prefix.size() + reply.size();
      peer.deadline = Clock::now() + std::chrono::seconds{5};
      return false;
    }
    return false;
  }

  Memory &memory_;
  LocalListener listener_;
  Handler &handler_;
  CompletionSignal wake_;
  std::array<std::optional<Peer>, Limits::peers> peers_;
  std::atomic<bool> stopping_{false};
  DropChannel<Attachment, Limits::peers, ChannelPolicy::keep_oldest> attachments_;
  std::thread worker_;
};

}
}
