#pragma once

#include "paths.hpp"

namespace telar::runtime::proxy_trust {

enum class Status { absent,
                    installed,
                    stale };

inline std::string_view statusName(Status status) noexcept {
  switch (status) {
  case Status::absent:
    return "absent";
  case Status::installed:
    return "installed";
  case Status::stale:
    return "stale";
  }

  std::unreachable();
}

struct Inspection {
  Status status = Status::absent;
  std::optional<Record> record;
};

inline constexpr auto rotation_window = std::chrono::hours{24};

inline void validateTarget(const Record &record, std::string_view keychain) {
  if (record.backend != Backend::macos || record.store.view() != keychain) {
    throw std::invalid_argument{"Invalid proxy trust record target"};
  }
}

template <ConcurrentAllocator Memory>
Inspection inspect(Memory &memory, const TlsLibrary<Memory> &library, const Paths<Memory> &paths, std::string_view keychain) noexcept {
  Inspection result;
  try {
    const auto directory = paths.open();
    if (!directory) {
      return result;
    }

    result.record = Record::read(memory, directory.get());
    if (!result.record) {
      return result;
    }

    validateTarget(*result.record, keychain);
    Paths<Memory>::validateDirectory(directory.get());
    const auto authority = CertificateAuthority<Memory>::loadExisting(memory, library, directory.get(), AuthorityKind::system_trust);
    result.status = authority && authority->fingerprint() == result.record->fingerprint && !authority->expiresWithin(rotation_window) ? Status::installed : Status::stale;
  } catch (...) {
    result.status = Status::stale;
  }

  return result;
}

}
