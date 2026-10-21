#include "wallpaper_panels.hpp"
#include "surface_panel.hpp"
#include <QDebug>
#include <stdexcept>

@implementation TelarWallpaperPanels {
  ui::DesktopUi *_desktop;
  NSMutableDictionary<NSNumber *, TelarSurfacePanel *> *_panels;
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

- (void)reconcileScreens {
  NSMutableDictionary<NSNumber *, NSScreen *> *screens = [NSMutableDictionary dictionary];

  for (NSScreen *screen in NSScreen.screens) {
    NSNumber *identifier = screen.deviceDescription[@"NSScreenNumber"];

    if (identifier) {
      screens[identifier] = screen;
    }
  }

  for (NSNumber *identifier in _panels.allKeys) {
    if (!screens[identifier]) {
      [_panels[identifier] close];
      [_panels removeObjectForKey:identifier];
    }
  }

  for (NSNumber *identifier in screens) {
    if (_panels[identifier]) {
      continue;
    }

    TelarSurfacePanel *panel = [[TelarSurfacePanel alloc] initWithScreen:screens[identifier]
                                                                    kind:ui::SurfaceKind::wallpaper
                                                                 desktop:*_desktop];

    if (!panel) {
      throw std::runtime_error("Unable to create wallpaper panel");
    }

    _panels[identifier] = panel;
    [panel orderFrontRegardless];
  }
}

- (void)screensChanged:(NSNotification *)notification {
  if (!_visible) {
    return;
  }

  try {
    [self reconcileScreens];
  } catch (const std::exception &error) {
    qWarning() << "Wallpaper display update failed:" << error.what();
  }
}

- (void)show {
  _visible = YES;
  [self reconcileScreens];
}

- (void)close {
  _visible = NO;
  [NSNotificationCenter.defaultCenter removeObserver:self];

  for (TelarSurfacePanel *panel in _panels.allValues) {
    [panel close];
  }

  [_panels removeAllObjects];
}

- (void)dealloc {
  [self close];
}

@end
