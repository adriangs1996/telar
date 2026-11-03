#pragma once

#include "direction.hpp"
#include "flow_key.hpp"
#include "route_path.hpp"
#include "target.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_plugins/identity.hpp"
#include <net/if.h>

namespace telar::runtime::redirect {

struct Mapping {
  Target target;
  std::uint16_t listener_port = 0;
  bool incoming = false;

  // Established inbound packets can hit NAT state on the physical interface;
  // preserve the local IP so their translated destination remains deliverable.
  std::string_view listenerAddress() const noexcept {
    return incoming ? target.host.view() : target.endpoint.storage.ss_family == AF_INET6 ? "::1" : "127.0.0.1";
  }
};

struct Bypass {
  FlowKey key;
  RoutePath route;
};

struct PfScope {
  uid_t uid;
  std::string_view label;
  std::string_view discovery_interface;
  std::span<const FlowKey> flows;
  std::optional<unsigned> log_interface{};
  std::span<const Bypass> bypasses{};
  bool log_all = false;
  Direction direction = Direction::outbound;
  std::span<const FlowKey> incoming_flows{};
};

template <Allocator Memory>
class PfIdentity {
public:
  explicit PfIdentity(Memory &memory, std::string_view endpoint)
      : anchor(AllocatorRef<char, Memory>{memory}), label(AllocatorRef<char, Memory>{memory}) {
    const auto hash = plugins::stableId(endpoint);
    std::array<char, 32> hex{};
    std::snprintf(hex.data(), hex.size(), "tlr_%016llx", static_cast<unsigned long long>(hash));
    label = hex.data();
    anchor = "com.apple/telar-redirect-";
    anchor += label;
  }

  String<Memory> anchor;
  String<Memory> label;
};

template <Allocator Memory>
String<Memory> pfRules(Memory &memory, std::span<const Mapping> mappings, const PfScope &scope) {
  const auto uid = scope.uid;
  const auto label = scope.label;
  const auto interface = scope.discovery_interface;
  if (uid == 0 || mappings.empty() || mappings.size() > Target::maximum_targets || label.empty() || label.size() > 48 || label.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") != std::string_view::npos || !interface.starts_with("utun") || interface.size() <= 4 || interface.size() >= IFNAMSIZ || interface.substr(4).find_first_not_of("0123456789") != std::string_view::npos || scope.flows.size() + scope.incoming_flows.size() + scope.bypasses.size() > 256 || (!allowsIncoming(scope.direction) && !allowsOutgoing(scope.direction)) || (!allowsOutgoing(scope.direction) && (!scope.flows.empty() || !scope.bypasses.empty())) || (!allowsIncoming(scope.direction) && !scope.incoming_flows.empty())) {
    throw std::invalid_argument{"Invalid transparent redirect scope"};
  }
  String<Memory> rules{AllocatorRef<char, Memory>{memory}};
  if ((scope.log_interface && *scope.log_interface >= 16) || (allowsIncoming(scope.direction) && !std::ranges::any_of(mappings, [](const auto &mapping) { return mapping.incoming; }))) { throw std::invalid_argument{"Invalid incoming discovery scope"}; }
  std::array<char, 512> line{};
  for (const auto &mapping : mappings) {
    if (mapping.listener_port == 0 || (mapping.target.host.view() == "127.0.0.1" && mapping.listener_port == mapping.target.port) || (mapping.target.host.view() == "::1" && mapping.listener_port == mapping.target.port)) {
      throw std::invalid_argument{"Redirect listener overlaps its destination"};
    }
  }
  // Discovery has already selected the account. Exact tuples survive loopback
  // metadata changes and cannot match the helper's distinct upstream sockets.
  for (const auto &flow : scope.incoming_flows) {
    if (!std::ranges::any_of(mappings, [&](const auto &mapping) { return mapping.incoming && FlowKey::same(mapping.target, flow.destination); })) { throw std::invalid_argument{"Incoming flow is outside the local destination scope"}; }
  }
  for (const auto &bypass : scope.bypasses) {
    const auto &flow = bypass.key;
    const auto name = bypass.route.interface.view();
    const auto gateway = bypass.route.gateway.view();
    const auto family = flow.destination.endpoint.storage.ss_family;
    std::array<char, INET6_ADDRSTRLEN> text{};
    std::array<Byte, sizeof(in6_addr)> address{};
    if (name.empty() || name.size() >= IFNAMSIZ || name == interface || name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != std::string_view::npos || gateway.empty() || gateway.size() >= text.size() || family != flow.source.endpoint.storage.ss_family || !std::ranges::any_of(mappings, [&](const auto &mapping) { return FlowKey::same(mapping.target, flow.destination); })) { throw std::invalid_argument{"Invalid original route bypass"}; }
    std::ranges::copy(gateway, text.begin());
    if (::inet_pton(family, text.data(), address.data()) != 1) { throw std::invalid_argument{"Bypass gateway must be numeric"}; }
  }
  for (const auto group : {scope.flows, scope.incoming_flows}) {
    for (const auto &flow : group) {
      const auto selected = std::ranges::find_if(mappings, [&](const auto &mapping) { return FlowKey::same(mapping.target, flow.destination); });
      if (selected == mappings.end() || flow.source.endpoint.storage.ss_family != flow.destination.endpoint.storage.ss_family) {
        throw std::invalid_argument{"Discovered flow is outside the redirect scope"};
      }
      const bool ipv6 = flow.destination.endpoint.storage.ss_family == AF_INET6;
      const auto source = flow.source.host.view();
      const auto destination = flow.destination.host.view();
      const auto listener = selected->listenerAddress();
      const auto count = std::snprintf(line.data(), line.size(), "rdr on lo0 %s proto tcp from %.*s port %u to %.*s port %u -> %.*s port %u\n", ipv6 ? "inet6" : "inet", static_cast<int>(source.size()), source.data(), flow.source.port, static_cast<int>(destination.size()), destination.data(), flow.destination.port, static_cast<int>(listener.size()), listener.data(), selected->listener_port);
      rules.append(line.data(), static_cast<std::size_t>(count));
    }
  }
  for (const auto &bypass : scope.bypasses) {
    const auto &flow = bypass.key;
    const auto source = flow.source.host.view();
    const auto destination = flow.destination.host.view();
    const auto name = bypass.route.interface.view();
    const auto gateway = bypass.route.gateway.view();
    const auto count = std::snprintf(line.data(), line.size(), "pass out quick route-to (%.*s %.*s) %s proto tcp from %.*s port %u to %.*s port %u user %u flags S/SA no state\n", static_cast<int>(name.size()), name.data(), static_cast<int>(gateway.size()), gateway.data(), flow.destination.endpoint.storage.ss_family == AF_INET6 ? "inet6" : "inet", static_cast<int>(source.size()), source.data(), flow.source.port, static_cast<int>(destination.size()), destination.data(), flow.destination.port, uid);
    rules.append(line.data(), static_cast<std::size_t>(count));
  }
  for (const auto group : {scope.flows, scope.incoming_flows}) {
    for (const auto &flow : group) {
      const auto selected = std::ranges::find_if(mappings, [&](const auto &mapping) { return FlowKey::same(mapping.target, flow.destination); });
      const bool ipv6 = flow.destination.endpoint.storage.ss_family == AF_INET6;
      const auto source = flow.source.host.view();
      const auto listener = selected->listenerAddress();
      const auto count = std::snprintf(line.data(), line.size(), "pass in quick on lo0 %s proto tcp from %.*s port %u to %.*s port %u flags S/SA keep state label \"%.*s\"\n", ipv6 ? "inet6" : "inet", static_cast<int>(source.size()), source.data(), flow.source.port, static_cast<int>(listener.size()), listener.data(), selected->listener_port, static_cast<int>(label.size()), label.data());
      rules.append(line.data(), static_cast<std::size_t>(count));
    }
  }
  for (const auto &flow : scope.flows) {
    const bool ipv6 = flow.destination.endpoint.storage.ss_family == AF_INET6;
    const auto source = flow.source.host.view();
    const auto destination = flow.destination.host.view();
    const auto count = std::snprintf(line.data(), line.size(), "pass out quick route-to (lo0 %s) %s proto tcp from %.*s port %u to %.*s port %u user %u flags any no state\n", ipv6 ? "::1" : "127.0.0.1", ipv6 ? "inet6" : "inet", static_cast<int>(source.size()), source.data(), flow.source.port, static_cast<int>(destination.size()), destination.data(), flow.destination.port, uid);
    rules.append(line.data(), static_cast<std::size_t>(count));
  }
  for (const auto &flow : scope.incoming_flows) {
    const bool ipv6 = flow.destination.endpoint.storage.ss_family == AF_INET6;
    const auto source = flow.source.host.view();
    const auto destination = flow.destination.host.view();
    const auto count = std::snprintf(line.data(), line.size(), "pass in quick on ! lo0 route-to (lo0 %s) %s proto tcp from %.*s port %u to %.*s port %u user %u flags any no state\n", ipv6 ? "::1" : "127.0.0.1", ipv6 ? "inet6" : "inet", static_cast<int>(source.size()), source.data(), flow.source.port, static_cast<int>(destination.size()), destination.data(), flow.destination.port, uid);
    rules.append(line.data(), static_cast<std::size_t>(count));
  }
  for (const auto &mapping : mappings) {
    const bool ipv6 = mapping.target.endpoint.storage.ss_family == AF_INET6;
    const auto host = mapping.target.host.view();
    std::array<char, 48> logging{};
    if ((host == "::1" || scope.log_all) && scope.log_interface) {
      if (*scope.log_interface >= 16) { throw std::invalid_argument{"Invalid discovery log interface"}; }
      std::snprintf(logging.data(), logging.size(), " log (user, to pflog%u)", *scope.log_interface);
    }
    if (allowsOutgoing(scope.direction)) {
      const auto count = std::snprintf(line.data(), line.size(), "pass out%s quick on ! %.*s route-to %.*s %s proto tcp from any to %.*s port %u user %u flags S/SA no state\n", logging.data(), static_cast<int>(interface.size()), interface.data(), static_cast<int>(interface.size()), interface.data(), ipv6 ? "inet6" : "inet", static_cast<int>(host.size()), host.data(), mapping.target.port, uid);
      rules.append(line.data(), static_cast<std::size_t>(count));
    }
    if (allowsIncoming(scope.direction) && mapping.incoming && scope.log_interface) {
      const auto count = std::snprintf(line.data(), line.size(), "pass in log (user, to pflog%u) quick on ! lo0 route-to %.*s %s proto tcp from any to %.*s port %u user %u flags S/SA no state\n", *scope.log_interface, static_cast<int>(interface.size()), interface.data(), ipv6 ? "inet6" : "inet", static_cast<int>(host.size()), host.data(), mapping.target.port, uid);
      rules.append(line.data(), static_cast<std::size_t>(count));
    }
  }
  return rules;
}

}
