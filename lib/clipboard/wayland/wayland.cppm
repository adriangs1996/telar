export module telar.clipboard.wayland;

import std;
import telar.clipboard;
import telar.clipboard.linux;

// The Wayland backend of the Linux reader. libwayland-client's header and the generated
// wlr-data-control protocol stay in this module's units; the reader imports this declaration
// instead of including them.
export namespace telar::clipboard::linux_backend {
  std::expected<content, read_error> readWayland(deadline expires, std::size_t maximum_bytes);
}
