#include "screen_panels.hpp"
#include "surface_panel.hpp"
#include <QDebug>
#include <array>
#include <stdexcept>

namespace {
  // Bottom to top, so a display's bars come up over its wallpaper.
  constexpr std::array kinds{
      ui::SurfaceKind::wallpaper,
      ui::SurfaceKind::topbar,
      ui::SurfaceKind::sidebar,
  };
} // namespace

@implementation TelarScreenPanels {
  ui::DesktopUi *_desktop;
  NSMutableDictionary<NSNumber *, NSArray<TelarSurfacePanel *> *> *_panels;
  BOOL _visible;
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
    [panel orderFrontRegardless];
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

- (void)show {
  _visible = YES;
  [self reconcileScreens];
}

- (void)close {
  _visible = NO;
  [NSNotificationCenter.defaultCenter removeObserver:self];

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
