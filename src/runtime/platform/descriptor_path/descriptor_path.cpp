module telar.runtime.platform.descriptor_path;

import telar.sys.posix;
#ifdef __APPLE__
import telar.sys.apple;
#endif

import telar.platform.error;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // The path the open file `descriptor` has now, written terminated into `path`; false, with
    // errno set, when the system cannot tell or the path does not fit.
    bool resolve(int descriptor, ds::Array<char, PATH_MAX>& path) noexcept {
#ifdef __APPLE__
      return ::fcntl(descriptor, F_GETPATH, path.dataMut()) == 0; // NOLINT(cppcoreguidelines-pro-type-vararg): fcntl's C signature is variadic
#elifdef __linux__
      ds::Array<char, sizeof("/proc/self/fd/") + std::numeric_limits<int>::digits10 + 1> link{};

      std::snprintf(link.dataMut(), link.size(), "/proc/self/fd/%d", descriptor);

      const auto length = ::readlink(link.dataMut(), path.dataMut(), path.size());
      if (length <= 0) {
        return false;
      }

      if (static_cast<std::size_t>(length) >= path.size()) {
        sys::setLastError(ENAMETOOLONG);
        return false;
      }

      path.atMut(static_cast<std::size_t>(length)) = '\0';
      return true;
#else
      static_cast<void>(descriptor);
      static_cast<void>(path);
      sys::setLastError(ENOTSUP);
      return false;
#endif
    }

  }

  ds::Array<char, PATH_MAX> descriptorPath(int descriptor) {
    ds::Array<char, PATH_MAX> path{};
    if (!resolve(descriptor, path)) {
      throw SystemError{"Resolve open file path"};
    }

    return path;
  }

}
