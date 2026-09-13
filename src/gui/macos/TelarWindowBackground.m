#import "TelarWindowBackground.h"
#import "TelarBackgroundBlur.h"
#import <QuartzCore/QuartzCore.h>

@implementation TelarWindowBackground {
  NSVisualEffectView *effect;
  __weak NSView *terminal;
  TelarBackgroundBlur *blur;
  BOOL configured, opaque;
  uint32_t radius;
  NSInteger window_number;
  NSWindowStyleMask window_style;
}

- (instancetype)initWithContentView:(NSView *)content {
  self = [super initWithFrame:content.frame];
  if (self == nil) {
    return nil;
  }

  terminal = content;
  blur = [TelarBackgroundBlur new];
  effect = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
  effect.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  effect.material = NSVisualEffectMaterialUnderWindowBackground;
  effect.state = NSVisualEffectStateActive;
  effect.hidden = YES;
  [self addSubview:effect];
  content.frame = self.bounds;
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self addSubview:content];
  return self;
}

// Apply only on a changed frame appearance, e.g. [background applyFrame:&frame].
// Window alpha stays at one so glyphs and explicit cell backgrounds stay opaque.
- (void)applyFrame:(const telar_gui_frame *)frame {
  BOOL next_opaque = frame->background[3] >= 1.0f;
  uint32_t next_radius = next_opaque ? 0 : frame->background_blur;
  if (configured && opaque == next_opaque && radius == next_radius &&
      window_number == self.window.windowNumber && window_style == self.window.styleMask) {
    return;
  }

  configured = YES;
  opaque = next_opaque;
  radius = next_radius;
  window_number = self.window.windowNumber;
  window_style = self.window.styleMask;
  self.window.opaque = opaque;
  self.window.backgroundColor = NSColor.clearColor;
  terminal.layer.opaque = opaque;
  BOOL numeric_blur = [blur applyRadius:radius toWindow:self.window];
  effect.hidden = radius == 0 || numeric_blur;
  [self.window invalidateShadow];
}

- (uint32_t)appliedBlurRadius {
  return blur.appliedRadius;
}
@end
