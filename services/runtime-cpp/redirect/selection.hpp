#pragma once

#include "../proxy/name_resolutions.hpp"
#include "target.hpp"
#include "telar_base/request_error.hpp"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <poll.h>

namespace telar::runtime::redirect {

template <HostnameResolver Resolver = SystemNameResolver>
class Selection {
  using Resolutions = NameResolutions<Resolver>;
  using Clock = std::chrono::steady_clock;
  struct Pending {
    std::optional<typename Resolutions::Ticket> ticket;
    std::uint16_t port = 0;
  };

public:
  static constexpr std::size_t maximum_argument_bytes = INET6_ADDRSTRLEN + 8;

  explicit Selection(std::span<const std::string_view> input, const std::atomic<bool> &cancelled, Clock::time_point deadline) {
    if (input.empty() || input.size() > Target::maximum_targets) { throw std::invalid_argument{"Redirect requires 1..16 destinations"}; }
    std::array<Pending, Target::maximum_targets> pending;
    std::array<std::optional<Target>, Target::maximum_targets> numeric_targets;
    CompletionSignal signal;
    typename Resolutions::Notifications notifications{signal};
    std::size_t remaining = 0;
    for (std::size_t index = 0; index < input.size(); ++index) {
      check(cancelled, deadline);
      const auto authority = Target::authority(input[index]);
      const auto host = authority.hostname;
      const bool numeric = input[index].starts_with('[') || host.contains(':') || std::ranges::all_of(host, [](char byte) { return (byte >= '0' && byte <= '9') || byte == '.'; });
      if (numeric) {
        const auto target = Target::parse(input[index]);
        if (std::ranges::any_of(std::span{numeric_targets}.first(index), [&](const auto &other) { return other && other->host.view() == target.host.view() && other->port == target.port; })) { throw std::invalid_argument{"Duplicate redirect destination"}; }
        numeric_targets[index] = target;
        append(target);
        continue;
      }
      pending[index].port = authority.port;
      pending[index].ticket = Resolutions::request(host);
      if (!pending[index].ticket) { throw SystemError{"Redirect hostname resolver is at capacity", EAGAIN}; }
      ++remaining;
    }

    while (remaining != 0) {
      check(cancelled, deadline);
      for (auto &item : pending) {
        if (!item.ticket) { continue; }
        typename Resolutions::Result result;
        if (!item.ticket->collect(result)) { continue; }
        if (result.summary.error != 0 || result.summary.found == 0) { throw std::invalid_argument{"Redirect hostname resolution failed"}; }
        if (result.summary.found > result.addresses.size()) { throw std::invalid_argument{"Redirect hostname has too many addresses"}; }
        for (const auto &address : std::span{result.addresses}.first(result.summary.found)) { append(address, item.port); }
        item.ticket.reset();
        --remaining;
      }
      if (remaining != 0) {
        pollfd descriptor{signal.descriptor(), POLLIN, 0};
        if (::poll(&descriptor, 1, 20) < 0 && errno != EINTR) { throw SystemError{"Wait for redirect hostname resolution"}; }
        signal.drain();
      }
    }
  }

  std::span<const Target> targets() const noexcept { return std::span{targets_}.first(count_); }
  std::string_view argument(std::size_t index) const noexcept { return arguments_[index].view(); }

private:
  static void check(const std::atomic<bool> &cancelled, Clock::time_point deadline) {
    if (cancelled) { throw RequestError{FailureCode::invalid_request, "Redirect selection cancelled"}; }
    if (Clock::now() >= deadline) { throw RequestError{FailureCode::resource_limit, "Redirect hostname resolution deadline exceeded"}; }
  }

  void append(const NetworkAddress &address, std::uint16_t port) {
    const auto family = address.storage.ss_family;
    std::array<char, INET6_ADDRSTRLEN> host{};
    if (family == AF_INET) {
      if (address.length != sizeof(sockaddr_in) || !::inet_ntop(AF_INET, &reinterpret_cast<const sockaddr_in *>(&address.storage)->sin_addr, host.data(), host.size())) { throw std::invalid_argument{"Invalid resolved IPv4 destination"}; }
    } else if (family == AF_INET6) {
      const auto &v6 = *reinterpret_cast<const sockaddr_in6 *>(&address.storage);
      if (address.length != sizeof(sockaddr_in6) || v6.sin6_scope_id != 0 || !::inet_ntop(AF_INET6, &v6.sin6_addr, host.data(), host.size())) { throw std::invalid_argument{"Invalid resolved IPv6 destination"}; }
    } else { throw std::invalid_argument{"Resolved destination must use IP"}; }
    std::array<char, maximum_argument_bytes> text{};
    std::snprintf(text.data(), text.size(), family == AF_INET6 ? "[%s]:%u" : "%s:%u", host.data(), static_cast<unsigned>(port));
    append(Target::parse(text.data()));
  }

  void append(const Target &target) {
    if (std::ranges::any_of(targets(), [&](const auto &other) { return other.host.view() == target.host.view() && other.port == target.port; })) { return; }
    if (count_ == targets_.size()) { throw std::invalid_argument{"Resolved redirect selection exceeds 16 destinations"}; }
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
