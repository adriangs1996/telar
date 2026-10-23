#include "../../ui/workbench/native.hpp"
#include "spaces_bridge.hpp"
#include "virtual_spaces.hpp"
#include "../../trace.hpp"
#include <AppKit/AppKit.h>
#include <QWindow>
#include <stdexcept>

namespace workbench::native {
  Display display(std::uint32_t identifier) {
    TELAR_TRACE("native.display");
    for (NSScreen *screen in NSScreen.screens) {
      if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] != identifier) {
        continue;
      }

      const auto top = NSMaxY(NSScreen.screens.firstObject.frame);
      const auto rect = screen.visibleFrame;
      return {{NSMinX(rect), top - NSMaxY(rect), NSWidth(rect), NSHeight(rect)},
              screen.backingScaleFactor};
    }

    return {};
  }

  void place(QWindow &window, std::uint64_t space) {
    TELAR_TRACE("native.place");
    NSView *view = nil;
    {
      // The first call creates the native window.
      TELAR_TRACE("native.place.win_id");
      view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());
    }

    NSWindow *native = view.window;
    if (!native) {
      throw std::runtime_error("Qt did not create a native pane window");
    }

    {
      TELAR_TRACE("native.place.configure");
      native.collectionBehavior =
          NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorFullScreenAuxiliary;
      native.hidesOnDeactivate = NO;
      native.animationBehavior = NSWindowAnimationBehaviorNone;
      native.level = NSNormalWindowLevel;
    }

    const std::uint32_t windows[] = {static_cast<std::uint32_t>(native.windowNumber)};
    macos::spaces::moveToLayer(windows, macos::spaces::VirtualSpaces::get().stage(space));
  }

  void activate(QWindow &window) {
    TELAR_TRACE("native.activate");
    NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());
    macos::spaces::bringForward(static_cast<std::uint32_t>(view.window.windowNumber));
  }

  bool holdsKeyboard(QWindow &window) {
    NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());
    return NSApp.isActive && view.window.isKeyWindow;
  }

  void orderAbove(QWindow &window, std::uint32_t other) {
    TELAR_TRACE("native.order_above");
    NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());
    [view.window orderWindow:NSWindowAbove relativeTo:static_cast<NSInteger>(other)];
  }

  void prepareInputWindow(QWindow &window) {
    TELAR_TRACE("native.prepare_input_window");
    NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());
    NSWindow *native = view.window;

    if (!native) {
      throw std::runtime_error("Qt did not create the native keyboard window");
    }

    native.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient |
        NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary;
    native.ignoresMouseEvents = YES;
    native.hidesOnDeactivate = NO;
    native.animationBehavior = NSWindowAnimationBehaviorNone;
  }

  void commitComposition(QWindow &window) {
    TELAR_TRACE("native.commit_composition");
    auto *view = (__bridge NSView<NSTextInputClient> *)reinterpret_cast<void *>(window.winId());
    if (![view hasMarkedText]) {
      return;
    }

    [view unmarkText];
    [view.inputContext discardMarkedText];
  }

} // namespace workbench::native
