#pragma once

#include "control_protocol.hpp"
#include "../plugins/service_spec.hpp"
#include "../platform/file_descriptor.hpp"

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
