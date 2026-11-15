export module telar.clipboard.transfer;

import std;
import telar.clipboard;

// What the Wayland and X11 backends of the Linux reader share: the transfer deadline, the
// formats they look for, in order of preference, and bounded waits on a descriptor.
export namespace telar::clipboard::linux_backend {
  using clock = std::chrono::steady_clock;
  using deadline = clock::time_point;
  inline constexpr auto read_timeout = std::chrono::seconds(5);

  struct format {
    const char* target;
    std::string_view mime_type;
  };

  inline constexpr std::array formats = {
      format{"image/png", "image/png"},
      format{"image/jpeg", "image/jpeg"},
      format{"image/tiff", "image/tiff"},
      format{"text/plain;charset=utf-8", "text/plain;charset=utf-8"},
      format{"UTF8_STRING", "text/plain;charset=utf-8"},
      format{"text/plain", "text/plain"},
  };

  class descriptor {
  public:
    explicit descriptor(int value);
    ~descriptor();

    descriptor(const descriptor&) = delete;
    descriptor& operator=(const descriptor&) = delete;

    int get() const;

  private:
    int value_;
  };

  // Waits until `fd` reports one of the poll `events`, or fails once `expires` passes.
  std::expected<void, read_error> wait(int fd, short events, deadline expires);
}
