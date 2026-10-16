#include "topbar.hpp"
#include "metal_view.hpp"
#include <AppKit/AppKit.h>
#include <Foundation/Foundation.h>

@implementation TelarTopBar

- (instancetype)initWithScreen:(NSScreen *)screen {

  // ** Configurar la ventana que contiene la Barra  **
  constexpr CGFloat bar_height = 36.0;

  const NSRect available = screen.visibleFrame;
  const NSRect frame =
      NSMakeRect(NSMinX(available), NSMaxY(available) - bar_height, NSWidth(available), bar_height);

  self = [super initWithContentRect:frame
                          styleMask:NSWindowStyleMaskBorderless
                            backing:NSBackingStoreBuffered
                              defer:NO];

  if (!self) {
    return nil;
  }

  self.releasedWhenClosed = NO;
  self.hidesOnDeactivate = NO;
  self.level = NSFloatingWindowLevel;
  self.collectionBehavior =
      NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

  self.backgroundColor = NSColor.windowBackgroundColor;
  self.hasShadow = YES;
  self.title = @"Telar Top Bar";

  // ** FIN DE CONFIGURACION DE VENTANA **

  // **     CREAR LA VISTA DE METAL QUE SE RENDEREA DENTRO DE LA VENTA CONFIGURADA **
  TelarMetalView *view = [[TelarMetalView alloc] initWithFrame:self.contentView.bounds];
  if (!view) {
    return nil;
  }

  self.contentView = view;
  // ** FIN DE LA CONFIGURACION DE METAL  **

  return self;
}

@end
