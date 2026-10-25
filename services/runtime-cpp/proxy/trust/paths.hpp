#pragma once

#include "../../platform/private_directory.hpp"
#include "../../platform/process_environment.hpp"
#include "../../tls/authority.hpp"
#include "record.hpp"

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
    FileDescriptor descriptor{::open(directory_.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
    if (!descriptor && errno != ENOENT) {
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

private:
  String<Memory> directory_;
};

template <Allocator Memory>
Paths(Memory &memory, std::string_view directory) -> Paths<Memory>;

}
