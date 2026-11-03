#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_config/proxy/hostname.hpp"
#include <array>
#include <span>
#include <string_view>

namespace telar::runtime {

template <Allocator Memory>
class ProxyHostPolicy {
public:
  static constexpr std::size_t maximum_hosts = 256;
  static constexpr std::size_t maximum_hostname_bytes = ProxyHostname::maximum_bytes;

  explicit ProxyHostPolicy(Memory &memory)
      : patterns_(AllocatorRef<String<Memory>, Memory>{memory}) {}

  static bool validPattern(std::string_view pattern) noexcept {
    return ProxyHostname::validPattern(pattern);
  }

  bool append(std::string_view pattern) {
    if (patterns_.size() == maximum_hosts || !validPattern(pattern)) {
      return false;
    }

    std::array<char, INET6_ADDRSTRLEN> numeric{};
    if (const auto address = ProxyHostname::ipv6(pattern)) {
      ::inet_ntop(AF_INET6, &*address, numeric.data(), numeric.size());
      pattern = numeric.data();
    }
    patterns_.emplace_back(pattern, AllocatorRef<char, Memory>{patterns_.get_allocator().memory()});
    std::ranges::transform(patterns_.back(), patterns_.back().begin(), asciiLower);
    return true;
  }

  void finish() {
    std::ranges::sort(patterns_);
    const auto duplicates = std::ranges::unique(patterns_);
    patterns_.erase(duplicates.begin(), duplicates.end());
  }

  void clear() noexcept {
    patterns_.clear();
  }

  bool contains(std::string_view hostname) const noexcept {
    if (hostname.empty() || patterns_.empty()) {
      return false;
    }
    if (patterns_.front() == "*") {
      return true;
    }
    if (hostname.size() > maximum_hostname_bytes) {
      return false;
    }

    if (const auto address = ProxyHostname::ipv6(hostname)) {
      std::array<char, INET6_ADDRSTRLEN> numeric{};
      ::inet_ntop(AF_INET6, &*address, numeric.data(), numeric.size());
      return find(numeric.data());
    }

    std::array<char, maximum_hostname_bytes + wildcard_prefix.size()> canonical;
    std::ranges::transform(hostname, canonical.begin() + wildcard_prefix.size(), asciiLower);
    const std::string_view exact{canonical.data() + wildcard_prefix.size(), hostname.size()};
    if (find(exact)) {
      return true;
    }

    for (auto dot = hostname.find('.'); dot != std::string_view::npos; dot = hostname.find('.', dot + 1)) {
      const auto start = dot + 1;
      std::ranges::copy(wildcard_prefix, canonical.data() + start);
      if (find({canonical.data() + start, hostname.size() - start + wildcard_prefix.size()})) {
        return true;
      }
    }
    return false;
  }

  std::span<const String<Memory>> patterns() const noexcept {
    return patterns_;
  }

private:
  bool find(std::string_view pattern) const noexcept {
    const auto found = std::lower_bound(patterns_.begin(), patterns_.end(), pattern, [](const auto &entry, std::string_view value) { return std::string_view{entry} < value; });
    return found != patterns_.end() && *found == pattern;
  }

  static constexpr std::string_view wildcard_prefix = "*.";
  Vector<String<Memory>, Memory> patterns_;
};

}
