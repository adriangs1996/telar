module;
#include <limits>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <type_traits>
#include <cstdio>

#include <cstddef>
#include <sys/param.h>
#include <cerrno>
#include <exception>
#include <array>
#include <cstdint>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <optional>
#include <stdexcept>
#include <stop_token>
#include <string_view>
#include <span>
#include <algorithm>
#include <unistd.h>
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include <chrono>
#include <semaphore>
#include <sys/file.h>
#include <sys/types.h>
#include <utility>
#if (defined(__APPLE__))
#include <sys/stdio.h>
#endif
#if (defined(__APPLE__))
#include <sys/unistd.h>
#endif
#if (!(defined(__APPLE__)))
#include <cstdio>
#endif
#if (!(defined(__APPLE__)))
#endif

module telar.gui.platform.profile_file;


import telar.gui.platform.private_file_stamp;
import telar.platform;
import telar.gui.text.json_unsigned_integer;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.platform.primitives;


#ifdef __APPLE__
#include <sys/stdio.h>
#include <sys/unistd.h>
#else
#include <cstdio>
#endif

namespace telar::gui::platform {

namespace {

struct PrivateMode {
  static constexpr mode_t file = 0600;
  static constexpr mode_t shared = 0077;
};

void requirePrivateRegularFile(int descriptor) {
  struct stat state{};
  if (::fstat(descriptor, &state) != 0) {
    throw runtime::SystemError{"Inspect machine profile file"};
  }

  if (!S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & PrivateMode::shared) != 0) {
    throw InsecureProfileFile{};
  }
}

runtime::FileDescriptor openProfileLockFile(int directory, std::string_view name) {
  try {
    try {
      return runtime::openBeneath(directory, name, O_RDWR | O_CREAT | O_EXCL, PrivateMode::file);
    } catch (const runtime::SystemError &error) {
      if (error.code() != EEXIST) {
        throw;
      }
    }

    return runtime::openBeneath(directory, name, O_RDWR);
  } catch (const runtime::SystemError &error) {
    if (error.code() == ELOOP) {
      throw InsecureProfileFile{};
    }

    throw runtime::SystemError{"Open machine profile lock", error.code()};
  }
}

void waitForProfileLock(int descriptor, const std::stop_token &stop) {
  std::binary_semaphore cancellation{0};
  const std::stop_callback notify_stop{stop, [&cancellation] {
                                         cancellation.release();
                                       }};
  constexpr auto retry_interval = std::chrono::milliseconds{20};
  for (;;) {
    if (stop.stop_requested()) {
      throw ProfileOperationCancelled{};
    }

    if (::flock(descriptor, LOCK_EX | LOCK_NB) == 0) {
      return;
    }

    if (errno == EINTR) {
      continue;
    }

    if (errno != EWOULDBLOCK && errno != EAGAIN) {
      throw runtime::SystemError{"Lock machine profiles"};
    }

    static_cast<void>(cancellation.try_acquire_for(retry_interval));
  }
}

class TemporaryProfileFile {
public:
  explicit TemporaryProfileFile(int parent)
      : parent_(parent) {
    constexpr unsigned maximum_attempts = 8;
    for (unsigned attempt = 0; attempt < maximum_attempts; ++attempt) {
      generateName();
      try {
        file_ = runtime::openBeneath(parent_, name_.data(), O_WRONLY | O_CREAT | O_EXCL, PrivateMode::file);

        return;
      } catch (const runtime::SystemError &error) {
        if (error.code() != EEXIST) {
          throw runtime::SystemError{"Create temporary machine profile file", error.code()};
        }
      }
    }

    throw runtime::SystemError{"Create unique machine profile file", EEXIST};
  }

  ~TemporaryProfileFile() {
    if (!committed_) {
      ::unlinkat(parent_, name_.data(), 0);
    }
  }

  TemporaryProfileFile(const TemporaryProfileFile &) = delete;
  TemporaryProfileFile &operator=(const TemporaryProfileFile &) = delete;
  TemporaryProfileFile(TemporaryProfileFile &&) = delete;
  TemporaryProfileFile &operator=(TemporaryProfileFile &&) = delete;

  void replace(const char *destination, std::string_view source) {
    if (const auto failure = runtime::writeDescriptor(file_.get(), byteView(source)); failure != 0) {
      throw runtime::SystemError{"Write machine profiles", failure};
    }

    if (::fsync(file_.get()) != 0) {
      throw runtime::SystemError{"Sync machine profiles"};
    }

    file_.reset();
    if (::renameat(parent_, name_.data(), parent_, destination) != 0) {
      throw runtime::SystemError{"Replace machine profiles"};
    }

    committed_ = true;
  }

private:
  static constexpr std::string_view prefix = ".telar-machine-profile-";
  static constexpr std::string_view hexadecimal = "0123456789abcdef";
  static constexpr std::size_t nonce_bytes = 16;
  static constexpr unsigned hexadecimal_bits = 4;

  void generateName() {
    std::array<std::uint8_t, nonce_bytes> nonce{};
    SecureRandom::fill(nonce);

    std::ranges::copy(prefix, name_.begin());
    auto position = prefix.size();
    for (const auto byte : nonce) {
      name_[position++] = hexadecimal[byte >> hexadecimal_bits];
      name_[position++] = hexadecimal[byte % hexadecimal.size()];
    }
  }

  int parent_;
  std::array<char, prefix.size() + (nonce_bytes * 2) + 1> name_{};
  runtime::FileDescriptor file_;
  bool committed_ = false;
};

}

ProfileFile::ProfileFile(std::string_view path, std::stop_token stop)
    : stop_(std::move(stop)) {
  if (path.empty() || path.contains('\0') || path.ends_with('/')) {
    throw runtime::SystemError{"Invalid machine profile path", EINVAL};
  }

  BoundedText<PathLimits::path_bytes - 1> absolute;
  if (!path.starts_with('/')) {
    std::array<char, PathLimits::path_bytes> current{};
    if (::getcwd(current.data(), current.size()) == nullptr) {
      throw runtime::SystemError{"Resolve machine profile directory"};
    }

    absolute.append(current.data());
    absolute.append("/");
  }

  absolute.append(path);
  path_length_ = absolute.view().size();
  std::ranges::copy(absolute.view(), path_.begin());
  name_offset_ = absolute.view().rfind('/') + 1;
  const auto name = absolute.view().substr(name_offset_);
  if (name == "." || name == ".." || name.size() > PathLimits::component_bytes) {
    throw runtime::SystemError{"Invalid machine profile file name", EINVAL};
  }
}

std::string_view ProfileFile::path() const noexcept {
  return {path_.data(), path_length_};
}

ProfileFileTransaction ProfileFile::lock() const {
  std::array<char, PathLimits::path_bytes> parent_path{};
  const auto parent_length = std::max<std::size_t>(1, name_offset_ - 1);
  std::copy_n(path_.begin(), parent_length, parent_path.begin());
  runtime::createPrivateDirectory({parent_path.data(), parent_length});
  auto parent = runtime::openPrivateParent(path());
  const auto name = path().substr(name_offset_);
  constexpr std::string_view lock_suffix = ".lock";
  BoundedText<PathLimits::component_bytes> lock_name;
  lock_name.append(name);
  lock_name.append(lock_suffix);
  auto held = openProfileLockFile(parent.get(), lock_name.view());

  requirePrivateRegularFile(held.get());
  waitForProfileLock(held.get(), stop_);

  return {std::move(parent), std::move(held), name};
}

ProfileFileTransaction::ProfileFileTransaction(runtime::FileDescriptor parent, runtime::FileDescriptor lock, std::string_view name)
    : parent_(std::move(parent)),
      lock_(std::move(lock)) {
  std::ranges::copy(name, name_.begin());
}

void ProfileFileTransaction::replace(std::string_view source) const {
  TemporaryProfileFile temporary{parent_.get()};
  temporary.replace(name_.data(), source);
}

}
