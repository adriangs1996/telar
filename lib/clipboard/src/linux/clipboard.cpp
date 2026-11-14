// Outside the module: the reader imports the Wayland and X11 backends, which import
// telar.clipboard, whose header declares read in the global module.
import std;
import telar.clipboard;
import telar.clipboard.linux;
import telar.clipboard.wayland;
import telar.clipboard.x11;

namespace telar::clipboard {
  std::expected<content, read_error> read(std::size_t maximum_bytes) {
    const auto expires = linux_backend::clock::now() + linux_backend::read_timeout;
    try {
      const char* wayland = std::getenv("WAYLAND_DISPLAY");
      if (wayland != nullptr && *wayland != '\0') {
        // Do not silently read an unrelated XWayland clipboard if Wayland access fails.
        return linux_backend::readWayland(expires, maximum_bytes);
      }

      const char* display = std::getenv("DISPLAY");
      if (display != nullptr && *display != '\0') {
        return linux_backend::readX11(expires, maximum_bytes);
      }

      return std::unexpected(read_error::session_unavailable);
    } catch (const std::bad_alloc&) {
      return std::unexpected(read_error::allocation_failed);
    } catch (const std::length_error&) {
      return std::unexpected(read_error::allocation_failed);
    }
  }
}
