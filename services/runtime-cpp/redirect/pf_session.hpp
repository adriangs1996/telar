#pragma once

#include "pf_rules.hpp"
#include <exception>

namespace telar::runtime::redirect {

template <typename Command, typename State, typename Loopback, Allocator Memory>
class PfSession {
public:
  explicit PfSession(Command &command, State &state, const PfIdentity<Memory> &identity, Loopback &loopback) noexcept
      : command_(command), state_(state), identity_(identity), loopback_(loopback) {}

  ~PfSession() {
    try {
      stop();
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar redirect cleanup: %s; retry traffic redirect-cleanup\n", error.what());
    }
  }

  PfSession(const PfSession &) = delete;
  PfSession &operator=(const PfSession &) = delete;

  void recover() {
    token_ = state_.load();
    stop();
  }

  void start(std::string_view rules) {
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

  void stop() {
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
    std::array<char, 32> value{};
    const auto result = std::to_chars(value.data(), value.data() + value.size(), *token_);
    if (*token_ != 0) {
      run({"-X", std::string_view{value.data(), static_cast<std::size_t>(result.ptr - value.data())}});
      token_ = 0;
      state_.save(0);
    }
    state_.clear();
    token_.reset();
  }

  static std::uint64_t parseToken(std::string_view output) {
    while (!output.empty()) {
      const auto newline = output.find('\n');
      auto line = output.substr(0, newline);
      if (line.starts_with("Token")) {
        const auto colon = line.find(':');
        if (colon != std::string_view::npos) {
          line.remove_prefix(colon + 1);
          const auto first = line.find_first_not_of(" \t");
          if (first != std::string_view::npos) {
            line.remove_prefix(first);
            line = line.substr(0, line.find_last_not_of(" \t\r") + 1);
            std::uint64_t token = 0;
            const auto result = std::from_chars(line.data(), line.data() + line.size(), token);
            if (result.ec == std::errc{} && result.ptr == line.data() + line.size() && token != 0) {
              return token;
            }
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

  void replace(std::string_view rules) {
    if (!token_) {
      throw std::runtime_error{"Redirect session is not enabled"};
    }
    run({"-a", identity_.anchor, "-f", "-"}, rules);
  }

private:
  auto run(std::initializer_list<std::string_view> arguments, std::string_view input = {}) {
    return command_.run(std::span{arguments.begin(), arguments.size()}, input);
  }

  Command &command_;
  State &state_;
  const PfIdentity<Memory> &identity_;
  Loopback &loopback_;
  std::optional<std::uint64_t> token_;
};

}
