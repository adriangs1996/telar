#pragma once

#include "../proxy/authority_directory.hpp"
#include "../proxy/trust/service.hpp"
#include "proxy_options.hpp"

namespace telar::runtime::cli {

template <ConcurrentAllocator Memory, EnvironmentLookup Environment>
int runProxyTrust(Memory &memory, const ProxyTrustOptions &options, const Environment &environment) {
  const auto directory = options.directory.empty() ? proxyAuthorityDirectory(memory, environment) : String<Memory>{options.directory, AllocatorRef<char, Memory>{memory}};
  if (directory.empty() || directory.front() != '/') {
    std::fputs("telar proxy trust: --ca-dir must be absolute\n", stderr);
    return 1;
  }

  const proxy_trust::Paths paths{memory, directory};
  const auto keychain = paths.keychain(memory, environment);
  const TlsLibrary library{memory};
  proxy_trust::SystemCommand command{memory, stdout};
  proxy_trust::Service service{memory, library, paths, command, keychain};
  const auto current = service.inspect();
  const auto certificate = paths.file(AuthorityFiles::forKind(AuthorityKind::system_trust).certificate);
  const auto print_notice = [&] {
    std::printf("Firefox may use its own certificate store; import %s there if it does not honor OS trust.\n", certificate.c_str());
  };

  if (options.action == ProxyTrustAction::status) {
    std::printf("telar proxy trust: %s (%s)\n", proxy_trust::statusName(current.status).data(), directory.c_str());
    if (current.record) {
      const auto &record = *current.record;
      std::printf("fingerprint: %.*s\nstore: %.*s\n", static_cast<int>(record.fingerprint.size()), record.fingerprint.data(), static_cast<int>(record.store.view().size()), record.store.view().data());
    }

    print_notice();
    return current.status == proxy_trust::Status::stale ? 1 : 0;
  }
  if (current.status == proxy_trust::Status::stale && !current.record) {
    const auto record = paths.file(proxy_trust::Record::filename);
    std::printf("telar proxy trust: invalid trust record (%s)\n", record.c_str());
    return 1;
  }

  if (options.action == ProxyTrustAction::install) {
    if (!options.linux_backend.empty()) {
      throw std::invalid_argument{"Linux trust backend is not supported on macOS"};
    }
    if (current.status == proxy_trust::Status::installed) {
      std::printf("telar proxy trust: already installed (%s)\n", directory.c_str());
    } else {
      const auto record = service.install(current.record);
      std::printf("telar proxy trust: installed %.*s\n", static_cast<int>(record.fingerprint.size()), record.fingerprint.data());
    }

    print_notice();
    return 0;
  }

  if (!current.record) {
    std::printf("telar proxy trust: not installed (%s)\n", directory.c_str());
    return 0;
  }

  service.uninstall(*current.record);
  std::printf("telar proxy trust: removed %.*s\n", static_cast<int>(current.record->fingerprint.size()), current.record->fingerprint.data());
  return 0;
}

}
