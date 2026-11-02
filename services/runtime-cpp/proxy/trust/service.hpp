#pragma once

#include "command.hpp"
#include "prepared_authority.hpp"

namespace telar::runtime::proxy_trust {

enum class Action { install, uninstall, rotate };

template <ConcurrentAllocator Memory, TrustCommandExecutor Executor>
class Service {
public:
  explicit Service(Memory &memory, const TlsLibrary<Memory> &library, const Paths<Memory> &paths, Executor &executor, Destination destination) noexcept
      : memory_(memory), library_(library), paths_(paths), executor_(executor), destination_(destination) {}

  Inspection inspect() const noexcept {
    return proxy_trust::inspect(memory_, library_, paths_, destination_);
  }

  Record install(const std::optional<Record> &previous, bool force_rotation = false) {
    TELAR_TRACE("proxy.installSystemTrust");
    if (destination_.store.view().empty()) {
      throw std::invalid_argument{"Home directory unavailable for proxy trust"};
    }
    if (previous) {
      validateTarget(*previous, destination_);
    }

    const auto directory = paths_.prepare();
    PreparedAuthority prepared{memory_, library_, directory.get(), AuthorityPreparation{.force_rotation = force_rotation}};
    const auto certificate = paths_.file(prepared.certificateName());
    Record replacement;
    replacement.backend = destination_.backend;
    replacement.fingerprint = prepared.authority().fingerprint();
    replacement.store = destination_.store;
    installAuthority(certificate);

    try {
      if (previous && previous->fingerprint != replacement.fingerprint && previous->backend != Backend::update_ca_certificates) {
        remove(*previous);
      }

      prepared.activate();
      replacement.write(memory_, directory.get());
      prepared.commit();
    } catch (...) {
      try {
        remove(replacement);
      } catch (const std::exception &error) {
        std::fprintf(stderr, "telar proxy trust: could not remove partially installed authority: %s\n", error.what());
      }

      throw;
    }

    return replacement;
  }

  void uninstall(const Record &record) {
    TELAR_TRACE("proxy.removeSystemTrust");
    validateTarget(record, destination_);
    const auto directory = paths_.open();
    if (!directory) {
      throw SystemError{"Proxy trust record disappeared", ENOENT};
    }

    remove(record);
    if (::unlinkat(directory.get(), Record::filename.data(), 0) != 0) {
      throw SystemError{"Remove proxy trust record"};
    }
  }

  std::optional<Record> rotateIfNeeded() {
    const auto current = inspect();
    if (current.status != Status::stale || !current.record) {
      return std::nullopt;
    }
    if (destination_.backend != Backend::macos) {
      return std::nullopt;
    }

    return install(current.record);
  }

private:
  void installAuthority(std::string_view certificate) {
    switch (destination_.backend) {
    case Backend::macos:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-k", destination_.store.view(), certificate}));
      break;
    case Backend::update_ca_certificates:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/install", "-m", "0644", certificate, destination_.store.view()}));
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/sbin/update-ca-certificates"}));
      break;
    case Backend::trust:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/trust", "anchor", certificate}));
      break;
    }
  }

  void remove(const Record &record) {
    switch (record.backend) {
    case Backend::macos:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/security", "delete-certificate", "-t", "-Z", {record.fingerprint.data(), record.fingerprint.size()}, record.store.view()}));
      break;
    case Backend::update_ca_certificates:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/rm", "-f", record.store.view()}));
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/sbin/update-ca-certificates"}));
      break;
    case Backend::trust:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/trust", "anchor", "--remove", record.store.view()}));
      break;
    }
  }

  Memory &memory_;
  const TlsLibrary<Memory> &library_;
  const Paths<Memory> &paths_;
  Executor &executor_;
  Destination destination_;
};

template <ConcurrentAllocator Memory, TrustCommandExecutor Executor>
Service(Memory &memory, const TlsLibrary<Memory> &library, const Paths<Memory> &paths, Executor &executor, Destination destination) -> Service<Memory, Executor>;

}
