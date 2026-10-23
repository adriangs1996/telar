#include "screen_panels.hpp"
#include "surface_panel.hpp"
#include "ui/desktop_ui.hpp"
#include "ui/services.hpp"
#include "ui/workbench/controller.hpp"
#include <QDebug>
#include <array>
#include <stdexcept>

namespace {
  // Bottom to top, so a display's bars come up over its wallpaper. The backstage switcher waits
  // ordered out until it opens on its display.
  constexpr std::array kinds{
      ui::SurfaceKind::wallpaper,
      ui::SurfaceKind::topbar,
      ui::SurfaceKind::sidebar,
      ui::SurfaceKind::backstage,
  };
} // namespace

@implementation TelarScreenPanels {
  ui::DesktopUi *_desktop;
  NSMutableDictionary<NSNumber *, NSArray<TelarSurfacePanel *> *> *_panels;
  BOOL _visible;
  std::uint64_t _workbench_subscription;
}

- (instancetype)initWithDesktop:(ui::DesktopUi &)desktop {
  self = [super init];

  if (self) {
    _desktop = &desktop;
    _panels = [NSMutableDictionary dictionary];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(screensChanged:)
               name:NSApplicationDidChangeScreenParametersNotification
             object:nil];
  }

  return self;
}

- (NSArray<TelarSurfacePanel *> *)panelsForScreen:(NSScreen *)screen {
  NSMutableArray<TelarSurfacePanel *> *panels = [NSMutableArray array];

  for (const auto kind : kinds) {
    TelarSurfacePanel *panel = [[TelarSurfacePanel alloc] initWithScreen:screen
                                                                    kind:kind
                                                                 desktop:*_desktop];

    if (!panel) {
      for (TelarSurfacePanel *created in panels) {
        [created close];
      }

      throw std::runtime_error("Unable to create a display's panels");
    }

    [panels addObject:panel];
    if (kind != ui::SurfaceKind::backstage) {
      [panel orderFrontRegardless];
    }
  }

  return panels;
}

- (void)reconcileScreens {
  NSMutableDictionary<NSNumber *, NSScreen *> *screens = [NSMutableDictionary dictionary];

  for (NSScreen *screen in NSScreen.screens) {
    NSNumber *identifier = screen.deviceDescription[@"NSScreenNumber"];

    if (identifier) {
      screens[identifier] = screen;
    }
  }

  for (NSNumber *identifier in _panels.allKeys) {
    if (screens[identifier]) {
      continue;
    }

    for (TelarSurfacePanel *panel in _panels[identifier]) {
      [panel close];
    }

    [_panels removeObjectForKey:identifier];
  }

  for (NSNumber *identifier in screens) {
    if (!_panels[identifier]) {
      _panels[identifier] = [self panelsForScreen:screens[identifier]];
    }
  }
}

- (void)screensChanged:(NSNotification *)notification {
  if (!_visible) {
    return;
  }

  try {
    [self reconcileScreens];
  } catch (const std::exception &error) {
    qWarning() << "Display panel update failed:" << error.what();
  }
}

// The switcher shows on the display the workbench opened it on, and nowhere else.
- (void)updateBackstage {
  auto *workbench = _desktop->services().workbench;
  const auto display = workbench ? workbench->switcherDisplay() : std::nullopt;

  for (NSNumber *identifier in _panels) {
    for (TelarSurfacePanel *panel in _panels[identifier]) {
      if (panel.kind != ui::SurfaceKind::backstage) {
        continue;
      }

      const bool shown = display && identifier.unsignedIntValue == *display;
      if (shown && !panel.visible) {
        [panel orderFrontRegardless];
      } else if (!shown && panel.visible) {
        [panel orderOut:nil];
      }
    }
  }
}

- (void)show {
  _visible = YES;
  [self reconcileScreens];

  auto *workbench = _desktop->services().workbench;
  if (workbench && !_workbench_subscription) {
    __weak TelarScreenPanels *weak = self;
    _workbench_subscription = workbench->subscribe([weak] {
      [weak updateBackstage];
    });
  }
}

- (void)close {
  _visible = NO;
  [NSNotificationCenter.defaultCenter removeObserver:self];

  auto *workbench = _desktop->services().workbench;
  if (workbench && _workbench_subscription) {
    workbench->unsubscribe(_workbench_subscription);
  }

  _workbench_subscription = 0;

  for (NSArray<TelarSurfacePanel *> *panels in _panels.allValues) {
    for (TelarSurfacePanel *panel in panels.reverseObjectEnumerator) {
      [panel close];
    }
  }

  [_panels removeAllObjects];
}

- (void)dealloc {
  [self close];
}

@end
