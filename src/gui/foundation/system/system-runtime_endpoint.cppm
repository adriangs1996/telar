export module telar.gui.foundation.system:runtime_endpoint;

import std;

import telar.sys.posix;

import telar.base.memory.containers;

export {
  namespace telar::gui::inline foundation::inline system::runtime_endpoint {
    using Path = runtime::FixedText<PATH_MAX>;

    // Why the endpoint could not be had, in a message kept without the heap.
    class Failure : public std::exception {
    public:
      template <typename... Parts>
      explicit Failure(const Parts&... parts) noexcept
          : message_(parts...) {}

      [[nodiscard]] const char* what() const noexcept override {
        return message_.c_str();
      }

    private:
      static constexpr std::size_t message_capacity = 511;

      runtime::ErrorText<message_capacity> message_;
    };

    // The socket of the user's own runtime, which `telar server endpoint` starts in the background
    // when none runs. telar runs through the user's login shell, so a runtime started from a
    // Finder or login launch gets the PATH, EDITOR and SHELL a terminal would, and so do its panes.
    // Blocks until telar answers or a deadline passes; throws Failure when it fails.
    Path resolve();
    Path program();
  }
}
