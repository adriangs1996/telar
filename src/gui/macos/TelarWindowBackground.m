#import "TelarWindowBackground.h"
#import <QuartzCore/QuartzCore.h>

@implementation TelarWindowBackground {
  NSVisualEffectView *effect;
  __weak NSView *terminal;
  BOOL configured, opaque, blurred;
}

- (instancetype)initWithContentView:(NSView *)content {
  self = [super initWithFrame:content.frame];
  if (self == nil) {
    return nil;
  }

  terminal = content;
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
  BOOL next_blurred = !next_opaque && frame->background_blur != 0;
  if (configured && opaque == next_opaque && blurred == next_blurred) {
    return;
  }

  configured = YES;
  opaque = next_opaque;
  blurred = next_blurred;
  self.window.opaque = opaque;
  self.window.backgroundColor = NSColor.clearColor;
  terminal.layer.opaque = opaque;
  effect.hidden = !blurred;
  [self.window invalidateShadow];
}
@end
