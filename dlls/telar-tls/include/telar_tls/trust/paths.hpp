#pragma once

#include "telar_platform/private_directory.hpp"
#include "telar_platform/process_environment.hpp"
#include "telar_tls/authority.hpp"
#include "telar_tls/trust/destination.hpp"
#include "telar_tls/trust/record.hpp"

namespace telar::runtime::proxy_trust {

template <Allocator Memory>
class Paths {
public:
  explicit Paths(Memory &memory, std::string_view directory)
      : directory_(directory, AllocatorRef<char, Memory>{memory}) {
    if (directory.empty() || directory.front() != '/' || directory.contains('\0') || directory.size() + AuthorityFiles::forKind(AuthorityKind::system_trust).certificate.size() + 1 >= PATH_MAX) {
      throw std::invalid_argument{"Proxy authority directory must be an absolute bounded path"};
    }
  }

  const String<Memory> &directory() const noexcept { return directory_; }

  String<Memory> file(std::string_view name) const {
    auto path = directory_;
    path += '/';
    path += name;
    if (path.size() >= PATH_MAX) {
      throw std::length_error{"Proxy authority file path exceeds its bound"};
    }

    return path;
  }

  FileDescriptor open() const {
    // A path that names no directory holds no trust record, as for Zig.
    FileDescriptor descriptor{::open(directory_.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
    if (!descriptor && errno != ENOENT && errno != ENOTDIR) {
      throw SystemError{"Open proxy authority directory"};
    }

    return descriptor;
  }

  FileDescriptor prepare() const {
    createPrivateDirectory(directory_);
    auto descriptor = open();
    if (!descriptor) {
      throw SystemError{"Open prepared proxy authority directory", ENOENT};
    }

    validateDirectory(descriptor.get());
    return descriptor;
  }

  static void validateDirectory(int descriptor) {
    struct stat state{};
    if (::fstat(descriptor, &state) != 0 || !S_ISDIR(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & 0077) != 0) {
      throw SystemError{"Validate proxy authority directory", EACCES};
    }
  }

  template <EnvironmentLookup Environment>
  static String<Memory> keychain(Memory &memory, const Environment &environment) {
    const auto home = environment.lookup("HOME");
    String<Memory> result{home, AllocatorRef<char, Memory>{memory}};
    if (home.empty()) {
      return result;
    }

    result += "/Library/Keychains/login.keychain-db";
    if (result.front() != '/' || result.size() > PATH_MAX || result.contains('\0')) {
      throw std::invalid_argument{"Invalid proxy trust keychain path"};
    }

    return result;
  }

  template <EnvironmentLookup Environment>
  Destination nativeDestination(Memory &memory, const Environment &environment, std::optional<Backend> selected = std::nullopt) const {
#if defined(__APPLE__)
    if (selected && *selected != Backend::macos) {
      throw std::invalid_argument{"Linux trust backend is not supported on macOS"};
    }
    return Destination{keychain(memory, environment)};
#else
    (void)environment;
    auto backend = selected.value_or(Backend::trust);
    if (!selected) {
      const auto directory = open();
      if (directory) {
        if (const auto record = Record::read(memory, directory.get())) {
          backend = record->backend;
        }
      }
    }
    if (backend == Backend::macos) {
      throw std::invalid_argument{"macOS trust backend is not supported on Linux"};
    }
    return Destination{backend, backend == Backend::trust ? std::string_view{file(AuthorityFiles::forKind(AuthorityKind::system_trust).certificate)} : linux_certificate_path};
#endif
  }

private:
  String<Memory> directory_;
};

template <Allocator Memory>
Paths(Memory &memory, std::string_view directory) -> Paths<Memory>;

}
