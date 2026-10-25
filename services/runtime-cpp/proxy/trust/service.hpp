#pragma once

#include "command.hpp"
#include "prepared_authority.hpp"

namespace telar::runtime::proxy_trust {

template <ConcurrentAllocator Memory, TrustCommandExecutor Executor>
class Service {
public:
  explicit Service(Memory &memory, const TlsLibrary<Memory> &library, const Paths<Memory> &paths, Executor &executor, std::string_view keychain) noexcept
      : memory_(memory), library_(library), paths_(paths), executor_(executor), keychain_(keychain) {}

  Inspection inspect() const noexcept {
    return proxy_trust::inspect(memory_, library_, paths_, keychain_);
  }

  Record install(const std::optional<Record> &previous) {
    TELAR_TRACE("proxy.installSystemTrust");
    if (keychain_.empty()) {
      throw std::invalid_argument{"Home directory unavailable for proxy trust"};
    }
    if (previous) {
      validateTarget(*previous, keychain_);
    }

    const auto directory = paths_.prepare();
    PreparedAuthority prepared{memory_, library_, directory.get()};
    const auto certificate = paths_.file(prepared.certificateName());
    Record replacement;
    replacement.fingerprint = prepared.authority().fingerprint();
    replacement.store.assign(keychain_);
    executor_.run(std::to_array<std::string_view>({"/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-k", keychain_, certificate}));

    try {
      if (previous && previous->fingerprint != replacement.fingerprint) {
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
    validateTarget(record, keychain_);
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

    return install(current.record);
  }

private:
  void remove(const Record &record) {
    executor_.run(std::to_array<std::string_view>({"/usr/bin/security", "delete-certificate", "-Z", {record.fingerprint.data(), record.fingerprint.size()}, record.store.view()}));
  }

  Memory &memory_;
  const TlsLibrary<Memory> &library_;
  const Paths<Memory> &paths_;
  Executor &executor_;
  std::string_view keychain_;
};

template <ConcurrentAllocator Memory, TrustCommandExecutor Executor>
Service(Memory &memory, const TlsLibrary<Memory> &library, const Paths<Memory> &paths, Executor &executor, std::string_view keychain) -> Service<Memory, Executor>;

}
