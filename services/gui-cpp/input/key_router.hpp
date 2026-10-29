#pragma once

#include "binding.hpp"
#include "key_event.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <utility>

namespace telar::gui {

template <typename Event>
concept BindingInput = requires(const Event &event) {
  { event.chord } -> std::convertible_to<KeyChord>;
  { event.phase } -> std::convertible_to<KeyPhase>;
  { event.physical } -> std::convertible_to<std::uint64_t>;
};

template <typename Action, BindingInput Event = BindingEvent>
class KeyRouter {
public:
  enum class Outcome : std::uint8_t {
    forward,
    replay,
    action,
    pending,
    discard,
  };

  struct Decision {
    Outcome outcome = Outcome::discard;
    Action action{};
    Event event{};
    std::array<Event, BindingLimits::keys> held{};
    std::size_t held_count = 0;
    bool has_current = false;
    bool repeated = false;
    std::uint64_t now_ns = 0;
  };

  struct Context {
    bool captures_keys = false;
    std::optional<BindingRepeat> repeat;
  };

  explicit KeyRouter(BindingMap<Action> map = BindingMap<Action>{}, std::optional<KeyChord> prefix = {})
      : map_(std::move(map)),
        prefix_(prefix),
        candidates_{0, map_.size()} {}

  [[nodiscard]] bool wantsBinding(const Event &event) const noexcept {
    if (event.phase != KeyPhase::press) {
      const auto *lease = findLease(event.physical);

      return lease != nullptr && lease->owner == Owner::binding;
    }

    const auto matched = map_.match({0, map_.size()}, 0, event.chord);

    return depth_ != 0 || matched.begin != matched.end;
  }

  [[nodiscard]] bool prefixPending() const noexcept {
    return prefix_pending_;
  }

  [[nodiscard]] std::optional<KeyChord> prefixedKeyForAction(const Action &action) const noexcept {
    if (!prefix_) {
      return std::nullopt;
    }

    for (const auto &binding : map_.configured()) {
      if (binding.length == 2 && binding.keys[0] == *prefix_ && binding.action == action) {
        return binding.keys[1];
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] bool hasPhysicalKey(std::uint64_t physical) const noexcept {
    return findLease(physical) != nullptr;
  }

  [[nodiscard]] std::optional<std::uint64_t> deadline() const noexcept {
    if (prefix_pending_ || !since_) {
      return {};
    }

    const auto available = std::numeric_limits<std::uint64_t>::max() - *since_;

    return *since_ + std::min(timeout_ns_, available);
  }

  void setTimeout(std::uint64_t timeout_ns) noexcept {
    timeout_ns_ = timeout_ns;
  }

  Decision expire(std::uint64_t now_ns) {
    const auto due = deadline();

    return due && now_ns >= *due ? replay() : Decision{.outcome = Outcome::pending};
  }

  Decision route(const Event &event, std::uint64_t now_ns, Context context = {}) {
    if (event.phase == KeyPhase::press) {
      repeating_.reset();
    }

    if (event.physical != 0) {
      if (event.phase == KeyPhase::press && !acquire(event.physical)) {
        return {};
      }

      if (event.phase != KeyPhase::press) {
        return routeLease(event, now_ns, context.repeat);
      }
    }

    if (context.captures_keys) {
      auto decision = replay();
      transfer(event.physical);
      if (decision.outcome == Outcome::replay) {
        decision.event = event;
        decision.has_current = true;

        return decision;
      }

      return {.outcome = Outcome::forward, .event = event};
    }

    const bool was_pending = depth_ != 0;
    auto decision = match(event, now_ns);
    if (decision.outcome == Outcome::forward) {
      transfer(event.physical);
    } else if (decision.outcome == Outcome::replay) {
      for (const auto &held : std::span{decision.held}.first(decision.held_count)) {
        transfer(held.physical);
      }

      transfer(event.physical);
    } else if (decision.outcome == Outcome::pending && !was_pending && !prefix_pending_) {
      since_ = now_ns;
    }

    if (depth_ == 0) {
      since_.reset();
    }

    return decision;
  }

  void actionCompleted(const Decision &decision, std::optional<BindingRepeat> policy) {
    if (!decision.repeated && decision.event.physical != 0 && policy && policy->interval_ns != 0) {
      repeating_ = Repeating{decision.event, decision.action, *policy, decision.now_ns};
    }
  }

  [[nodiscard]] std::optional<Action> repeatAction() const {
    return repeating_ ? std::optional{repeating_->action} : std::nullopt;
  }

  void eventFailed(const Event &event) noexcept {
    repeating_.reset();
    if (event.phase == KeyPhase::press) {
      release(event.physical);
    }
  }

  void inheritLeases(const KeyRouter &previous) noexcept {
    leases_ = previous.leases_;
    lease_count_ = previous.lease_count_;
    overflow_ = previous.overflow_;
    repeating_.reset();
  }

  void relinquish(std::uint64_t physical) noexcept {
    release(physical);
  }

  Decision interrupt() {
    repeating_.reset();

    return replay();
  }

  void cancelSequence() noexcept {
    resetMatch();
    since_.reset();
    repeating_.reset();
  }

  void clear() noexcept {
    cancelSequence();
    lease_count_ = 0;
  }

  [[nodiscard]] std::uint64_t overflowCount() const noexcept {
    return overflow_;
  }

private:
  enum class Owner : std::uint8_t {
    binding,
    application,
  };

  struct Lease {
    std::uint64_t physical = 0;
    Owner owner = Owner::binding;
  };

  struct Repeating {
    Event event;
    Action action;
    BindingRepeat policy;
    std::uint64_t last_ns = 0;
  };

  Lease *findLease(std::uint64_t physical) noexcept {
    auto *const end = leases_.begin() + lease_count_;
    auto *const found = std::ranges::find(leases_.begin(), end, physical, &Lease::physical);

    return physical == 0 || found == end ? nullptr : found;
  }

  [[nodiscard]] const Lease *findLease(std::uint64_t physical) const noexcept {
    const auto *const end = leases_.begin() + lease_count_;
    const auto *const found = std::ranges::find(leases_.begin(), end, physical, &Lease::physical);

    return physical == 0 || found == end ? nullptr : found;
  }

  bool acquire(std::uint64_t physical) noexcept {
    auto *slot = findLease(physical);
    if (slot == nullptr) {
      if (lease_count_ == leases_.size()) {
        ++overflow_;

        return false;
      }

      slot = &leases_[lease_count_++];
    }

    *slot = {.physical = physical, .owner = Owner::binding};

    return true;
  }

  void transfer(std::uint64_t physical) noexcept {
    if (auto *lease = findLease(physical)) {
      lease->owner = Owner::application;
    }
  }

  std::optional<Owner> release(std::uint64_t physical) noexcept {
    if (repeating_ && repeating_->event.physical == physical) {
      repeating_.reset();
    }

    auto *lease = findLease(physical);
    if (lease == nullptr) {
      return {};
    }

    const auto owner = lease->owner;
    *lease = leases_[--lease_count_];

    return owner;
  }

  Decision routeLease(const Event &event, std::uint64_t now_ns, std::optional<BindingRepeat> policy) {
    if (event.phase == KeyPhase::release) {
      return release(event.physical) == Owner::application ? Decision{.outcome = Outcome::forward, .event = event} : Decision{};
    }

    const auto *lease = findLease(event.physical);
    if (lease == nullptr) {
      return {};
    }

    if (lease->owner == Owner::application) {
      return {.outcome = Outcome::forward, .event = event};
    }

    if (!repeating_ || repeating_->event.physical != event.physical) {
      return {};
    }

    if (repeating_->event.chord != event.chord || policy != repeating_->policy) {
      repeating_.reset();

      return {};
    }

    if (now_ns < repeating_->last_ns || now_ns - repeating_->last_ns < repeating_->policy.interval_ns) {
      return {};
    }

    repeating_->last_ns = now_ns;

    return {.outcome = Outcome::action, .action = repeating_->action, .event = event, .repeated = true, .now_ns = now_ns};
  }

  Decision match(const Event &event, std::uint64_t now_ns) {
    constexpr KeyChord escape{.key = KeyChord::Key::escape};
    if (prefix_pending_ && event.chord == escape) {
      resetMatch();

      return {};
    }

    const auto candidates = depth_ == 0 ? typename BindingMap<Action>::Range{0, map_.size()} : candidates_;
    const auto matched = map_.match(candidates, depth_, event.chord);
    if (matched.begin == matched.end) {
      return missed(event);
    }

    const auto &binding = map_.at(matched.begin);
    if (binding.length == depth_ + 1) {
      const auto action = binding.action;
      resetMatch();

      return {.outcome = Outcome::action, .action = action, .event = event, .now_ns = now_ns};
    }

    held_[depth_] = event;
    ++depth_;
    candidates_ = matched;
    if (depth_ == 1 && prefix_) {
      prefix_pending_ = event.chord == *prefix_;
    }

    return {.outcome = Outcome::pending};
  }

  Decision missed(const Event &event) {
    if (depth_ == 0) {
      return {.outcome = Outcome::forward, .event = event};
    }

    auto decision = replay();
    if (decision.outcome == Outcome::replay) {
      decision.event = event;
      decision.has_current = true;
    }

    return decision;
  }

  Decision replay() {
    Decision decision;
    if (depth_ != 0 && !prefix_pending_) {
      decision.outcome = Outcome::replay;
      decision.held_count = depth_;
      std::copy_n(held_.begin(), depth_, decision.held.begin());
      for (const auto &held : std::span{held_}.first(depth_)) {
        transfer(held.physical);
      }
    }

    resetMatch();
    since_.reset();

    return decision;
  }

  void resetMatch() noexcept {
    candidates_ = {0, map_.size()};
    depth_ = 0;
    prefix_pending_ = false;
  }

  BindingMap<Action> map_;
  std::optional<KeyChord> prefix_;
  BindingMap<Action>::Range candidates_;
  std::array<Event, BindingLimits::keys> held_{};
  std::array<Lease, BindingLimits::physical_keys> leases_{};
  std::optional<Repeating> repeating_;
  std::optional<std::uint64_t> since_;
  std::uint64_t timeout_ns_ = BindingLimits::sequence_timeout_ns;
  std::uint64_t overflow_ = 0;
  std::size_t lease_count_ = 0;
  std::size_t depth_ = 0;
  bool prefix_pending_ = false;
};

}
