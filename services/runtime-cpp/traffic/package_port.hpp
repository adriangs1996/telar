#pragma once

#include "../plugins/service_spec.hpp"
#include "flow.hpp"
#include "telar_platform/file_descriptor.hpp"

namespace telar::runtime::traffic {

struct PackageChannel {
  FileDescriptor socket;
  std::uint64_t owner;
  int get() const noexcept { return socket.get(); }
};

// Only native runtime code can attach a package. Lua never supplies this grant
// or opens the authenticated endpoint; each registration gets its own channel.
class PackagePort {
public:
  virtual ~PackagePort() = default;
  virtual PackageChannel openPackage(const plugins::ServiceSpec &specification, std::uint32_t registration = 0) = 0;
  virtual void setPackageAvailable(std::uint64_t owner, bool available) noexcept = 0;
  virtual bool packagePending(std::uint64_t owner, std::uint64_t ticket, bool http) noexcept = 0;
  virtual void packageFailure(const plugins::ServiceSpec &, FlowEvent) noexcept {}
  virtual FileDescriptor openControl(const plugins::ServiceSpec &) { throw SystemError{"Package control is not available", EAGAIN}; }
  virtual void revokePackage(const plugins::ServiceSpec &) noexcept {}
};

}
