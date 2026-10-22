#include "../shortcuts.hpp"
#include "session.hpp"

struct NativeShortcuts::Impl {
  Shortcuts &shortcuts;

  explicit Impl(Shortcuts &service)
      : shortcuts(service) {
    linux_desktop::Session::get().shortcut = [this](Shortcuts::Request request) {
      shortcuts.submit(request);
    };
    shortcuts.setCapture([](Shortcuts::Capture capture) {
      linux_desktop::Session::get().capture(std::move(capture));
    });
    shortcuts.status = {true, {}};
  }

  ~Impl() {
    shortcuts.setCapture({});
    linux_desktop::Session::get().shortcut = {};
    shortcuts.status = {};
  }
};

NativeShortcuts::NativeShortcuts(Shortcuts &shortcuts)
    : impl_(std::make_unique<Impl>(shortcuts)) {}

NativeShortcuts::~NativeShortcuts() = default;
