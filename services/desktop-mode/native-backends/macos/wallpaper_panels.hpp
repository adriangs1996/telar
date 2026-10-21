#pragma once

#import <Foundation/Foundation.h>

namespace ui {
  class DesktopUi;
}

@interface TelarWallpaperPanels : NSObject
- (instancetype)initWithDesktop:(ui::DesktopUi &)desktop;
- (void)show;
- (void)close;
@end
