#pragma once

#import <Foundation/Foundation.h>

namespace ui {
  class DesktopUi;
}

// Every display is a desktop of its own: each one gets a wallpaper, a top bar and a sidebar,
// created and closed as displays come and go.
@interface TelarScreenPanels : NSObject
- (instancetype)initWithDesktop:(ui::DesktopUi &)desktop;
- (void)show;
- (void)close;
@end
