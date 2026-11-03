#include "backend.hpp"
#include <cstdlib>
#include <new>
#include <stdexcept>

namespace telar::clipboard {
  std::expected<content, read_error> read() {
    const auto expires = linux_backend::clock::now() + linux_backend::read_timeout;
    try {
      const char *wayland = std::getenv("WAYLAND_DISPLAY");
      if (wayland != nullptr && *wayland != '\0') {
        // Do not silently read an unrelated XWayland clipboard if Wayland access fails.
        return linux_backend::readWayland(expires);
      }

      const char *display = std::getenv("DISPLAY");
      if (display != nullptr && *display != '\0') {
        return linux_backend::readX11(expires);
      }

      return std::unexpected(read_error::session_unavailable);
    } catch (const std::bad_alloc &) {
      return std::unexpected(read_error::allocation_failed);
    } catch (const std::length_error &) {
      return std::unexpected(read_error::allocation_failed);
    }
  }
}
