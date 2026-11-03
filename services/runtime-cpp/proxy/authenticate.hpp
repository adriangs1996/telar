#pragma once

#include "authorization.hpp"
#include "target.hpp"
#include "telar_config/proxy/host_policy.hpp"
#include <variant>

namespace telar::runtime {

struct ProxyAdmission {
  ProxyTarget target;
  bool authenticated;
};

struct ProxyRejection {
  enum class Reason {
    invalid_authorization,
    unknown_credential,
    invalid_target
  };

  Reason reason;

  std::string_view response() const noexcept {
    if (reason == Reason::invalid_target) {
      return "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
    }
    return "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"telar\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  }
};

using ProxyDecision = std::variant<ProxyAdmission, ProxyRejection>;

template <Allocator Memory>
ProxyDecision authenticateProxy(const ProxySecret &secret, bool anonymous_tunnels, const ProxyHostPolicy<Memory> &policy, std::string_view head) noexcept {
  if (anonymous_tunnels && !ProxyAuthorization::present(head)) {
    const auto target = ProxyTarget::parse(head);
    if (!target) {
      return ProxyRejection{ProxyRejection::Reason::invalid_target};
    }
    if (policy.contains(target->hostname)) {
      return ProxyRejection{ProxyRejection::Reason::invalid_authorization};
    }
    return ProxyAdmission{*target, false};
  }

  const auto presented = ProxyAuthorization::parse(head);
  if (!presented) {
    return ProxyRejection{ProxyRejection::Reason::invalid_authorization};
  }
  if (!secret.matches(*presented)) {
    return ProxyRejection{ProxyRejection::Reason::unknown_credential};
  }

  const auto target = ProxyTarget::parse(head);
  if (!target) {
    return ProxyRejection{ProxyRejection::Reason::invalid_target};
  }
  return ProxyAdmission{*target, true};
}

}
