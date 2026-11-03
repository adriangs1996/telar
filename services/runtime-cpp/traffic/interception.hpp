#pragma once

#include "../platform/completion_signal.hpp"
#include "flow.hpp"
#include "telar_base/memory/erasing_allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/memory/sensitive_text.hpp"
#include "telar_config/proxy/host_policy.hpp"
#include <atomic>
#include <mutex>

namespace telar::runtime::traffic {

static constexpr std::uint32_t default_timeout_ms = 1000;
static constexpr std::uint32_t maximum_timeout_ms = 30000;

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

  static auto rule(std::span<Byte> output, InterceptionRule rule) -> std::span<const Byte> {
    plugins::FrameWriter writer{output};
    writer.tag(rule.http ? Command::http_rule : Command::rule);
    writer.text(rule.host);
    writer.integer(rule.directions);
    writer.integer(rule.visibility);
    writer.integer(rule.timeout_ms);
    writer.boolean(rule.fail_closed);
    return writer.finish();
  }

  static auto readRule(plugins::FrameReader &reader) -> InterceptionRule {
    InterceptionRule rule{.host = reader.text(), .directions = reader.integer<Byte>(), .visibility = reader.integer<Byte>(), .timeout_ms = reader.integer<std::uint32_t>(), .fail_closed = reader.boolean()};
    reader.finish();

    if (!ProxyHostname::validPattern(rule.host) || rule.directions == 0 || rule.directions > 3 || rule.visibility == 0 || rule.visibility > 3 || rule.timeout_ms == 0 || rule.timeout_ms > maximum_timeout_ms) {
      throw EncodingError{"Invalid interception rule"};
    }
    return rule;
  }

  static auto decision(std::span<Byte> output, std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes = {}) -> std::span<const Byte> {
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
    Registration(Memory &memory, Owner owner, InterceptionRule rule, std::uint64_t generation, std::uint64_t order) : route{owner, generation, rule.timeout_ms, rule.fail_closed, order}, hosts(memory), directions(rule.directions), visibility(rule.visibility) {
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
    Pending(Secure &memory, std::uint64_t ticket, const FlowEvent &event, std::span<const Route> matches) : ticket(ticket), decision_ticket(ticket), id(event.id), offset(event.offset), direction(event.direction), visibility(event.visibility), source(event.source), bytes(event.bytes.begin(), event.bytes.end(), AllocatorRef<Byte, Secure>{memory}), routes(matches.size()) {
      client.append(event.client);
      server.append(event.server);
      host.append(event.host);
      reason.append(event.reason);
      std::ranges::copy(matches, chain.begin());
    }

    auto event() const noexcept -> FlowEvent {
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
  explicit Interception(Memory &memory, CompletionSignal *completion = nullptr, CompletionSignal *requests = nullptr)
      : upstream_(memory), memory_(memory), completion_(completion ? *completion : wake_), request_signal_(requests ? *requests : requests_) {
    ::arc4random_buf(&next_, sizeof(next_));
    next_ >>= 1;
  }

  void configure(InterceptionRule rule) {
    configure(default_owner, rule);
  }

  auto policy(const FlowEvent &event) noexcept -> HttpPolicy {
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

  void configure(Owner owner, InterceptionRule rule, std::uint64_t order = UINT64_MAX) {
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

  void disconnect(Owner owner = default_owner) noexcept {
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

  void setAvailable(Owner owner, bool available) noexcept {
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

  bool pending(Owner owner, std::uint64_t ticket) noexcept {
    std::scoped_lock lock{mutex_};
    const auto *entry = registration(owner);
    if (!entry || !entry->available) { return false; }
    for (const auto &pending : pending_) {
      if (pending && pending->verdict == Verdict::pending && pending->decision_ticket == ticket && pending->chain[pending->step].owner == owner && pending->chain[pending->step].generation == entry->route.generation && std::chrono::steady_clock::now() < pending->deadline) { return true; }
    }
    return false;
  }

  auto begin(const FlowEvent &event) noexcept -> std::uint64_t {
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

  void decide(std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes) {
    decide(default_owner, ticket, verdict, bytes);
  }

  void decide(Owner owner, std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes) {
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

  auto poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept -> FlowControl::Decision {
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

  auto pending(std::uint64_t ticket) noexcept -> bool {
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
  void deliver(Owner owner, Consumer &&consumer) noexcept {
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

  int requestDescriptor() const noexcept { return request_signal_.descriptor(); }
  void drainRequests() noexcept { request_signal_.drain(); }
  auto completionSignal() noexcept -> CompletionSignal & { return completion_; }
  auto requestSignal() noexcept -> CompletionSignal & { return request_signal_; }

  void cancel(std::uint64_t ticket) noexcept {
    std::scoped_lock lock{mutex_};

    for (auto &slot : pending_) {
      if (slot && slot->ticket == ticket) {
        slot.reset();
        return;
      }
    }
  }

  std::optional<FlowControl::Time> deadline(std::uint64_t ticket) noexcept {
    std::lock_guard lock{mutex_};
    for (const auto &slot : pending_) {
      if (slot && slot->ticket == ticket) {
        return slot->deadline;
      }
    }
    return std::chrono::steady_clock::now();
  }

  int descriptor() const noexcept {
    return completion_.descriptor();
  }

  void drain() noexcept {
    completion_.drain();
  }

  static constexpr std::uint64_t rejected_ticket = UINT64_MAX;

private:
  auto registration(Owner owner) noexcept -> Registration * {
    for (auto &slot : registrations_) {
      if (slot && slot->route.owner == owner) {
        return &*slot;
      }
    }

    return nullptr;
  }

  static Verdict failure(const Pending &pending) noexcept {
    return pending.chain[pending.step].fail_closed ? Verdict::reject : Verdict::allow;
  }

  void advance(Pending &pending, Verdict verdict) noexcept {
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
