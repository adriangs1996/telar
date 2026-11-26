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
      [[tbc::generic]] explicit Failure(const Parts&... parts) noexcept
          : message_(parts...) {}

      [[nodiscard]] const char* what() const noexcept override;

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

    // The gateway program in the application bundle that holds this executable, or installed
    // beside it; otherwise the one on PATH. It reaches the runtimes of other machines.
    Path gatewayProgram();

    // Presents a pairing address to its gateway under `name`, and returns the address to save.
    // Blocks until the gateway answers; throws Failure with what it said when it refuses.
    Path pairMachine(std::string_view address, std::string_view name);
  }
}
