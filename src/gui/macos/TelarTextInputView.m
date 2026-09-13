#import "TelarTextInputView.h"

@implementation TelarTextInputView {
  TelarInputHandler input_handler;
  NSMutableAttributedString *marked;
  uint32_t text_phase, text_physical;
  telar_gui_input held_keys[256];
}

- (instancetype)initWithFrame:(NSRect)frame
                 inputHandler:(TelarInputHandler)handler {
  self = [super initWithFrame:frame];
  if (self == nil) {
    return nil;
  }

  input_handler = [handler copy];
  marked = [NSMutableAttributedString new];
  text_phase = 1;
  return self;
}

- (void)stopInput {
  input_handler = nil;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)sendInput:(telar_gui_input)event {
  if (input_handler == nil) {
    return NO;
  }

  if (!input_handler(event)) {
    NSBeep();
    return NO;
  }

  return YES;
}

- (void)sendText:(NSString *)text kind:(uint32_t)kind {
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  const BOOL scalar = text.length == 1 ||
      (text.length == 2 && CFStringIsSurrogateHighCharacter([text characterAtIndex:0]) &&
       CFStringIsSurrogateLowCharacter([text characterAtIndex:1]));
  uint32_t physical = kind == 1 && scalar ? text_physical : 0;
  telar_gui_input event = {.kind = kind,
                           .phase = kind == 1 ? text_phase : 1,
                           .text = data.bytes,
                           .len = data.length,
                           .physical = physical};
  if ([self sendInput:event] && physical != 0 && physical <= 256) {
    uint32_t code = text.length == 1 ? [text characterAtIndex:0] :
        CFStringGetLongCharacterForSurrogatePair([text characterAtIndex:0], [text characterAtIndex:1]);
    held_keys[physical - 1] = (telar_gui_input){.kind = 4, .code = code, .physical = physical, .phase = 1};
  }
}

- (void)paste:(id)sender {
  NSString *text =
      [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
  if (text != nil) {
    [self sendText:text kind:2];
  }
}

- (void)keyDown:(NSEvent *)event {
  text_phase = event.isARepeat ? 2 : 1;
  text_physical = event.keyCode < 256 ? event.keyCode + 1 : 0;
  [self handleKeyDown:event];
  text_physical = 0;
  text_phase = 1;
}

- (void)handleKeyDown:(NSEvent *)event {
  if ((event.modifierFlags & NSEventModifierFlagCommand) &&
      (event.modifierFlags & NSEventModifierFlagControl) &&
      [[event.charactersIgnoringModifiers lowercaseString] isEqualToString:@"f"]) {
    if (!event.isARepeat) {
      [self.window toggleFullScreen:nil];
    }

    return;
  }
  if ((event.modifierFlags & NSEventModifierFlagCommand) &&
      [[event.charactersIgnoringModifiers lowercaseString]
          isEqualToString:@"v"]) {
    [self paste:nil];
    return;
  }
  if (event.modifierFlags & NSEventModifierFlagCommand) {
    return;
  }

  uint32_t code = 0;
  switch (event.keyCode) {
  case 36:
  case 76:
    code = 1;
    break;
  case 48:
    code = 2;
    break;
  case 51:
    code = 3;
    break;
  case 53:
    code = 4;
    break;
  case 126:
    code = 5;
    break;
  case 125:
    code = 6;
    break;
  case 123:
    code = 7;
    break;
  case 124:
    code = 8;
    break;
  case 115:
    code = 9;
    break;
  case 119:
    code = 10;
    break;
  case 117:
    code = 11;
    break;
  case 116:
    code = 12;
    break;
  case 121:
    code = 13;
    break;
  }
  uint32_t mods = ((event.modifierFlags & NSEventModifierFlagShift) ? 1 : 0) |
                  ((event.modifierFlags & NSEventModifierFlagOption) ? 2 : 0) |
                  ((event.modifierFlags & NSEventModifierFlagControl) ? 4 : 0);
  if (code != 0) {
    telar_gui_input input = {.kind = 3,
                             .code = code,
                             .mods = mods,
                             .phase = event.isARepeat ? 2 : 1,
                             .physical = text_physical};
    if ([self sendInput:input] && input.physical != 0) {
      held_keys[input.physical - 1] = input;
    }
  } else if (mods & (2 | 4)) {
    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length == 1) {
      telar_gui_input input = {.kind = 4,
                               .code = [characters characterAtIndex:0],
                               .mods = mods,
                               .phase = event.isARepeat ? 2 : 1,
                             .physical = text_physical};
      if ([self sendInput:input] && input.physical != 0) {
        held_keys[input.physical - 1] = input;
      }
    }
  } else {
    if (marked.length != 0) {
      text_physical = 0;
    }

    [self interpretKeyEvents:@[ event ]];
  }
}

- (void)keyUp:(NSEvent *)event {
  if (event.keyCode >= 256 || held_keys[event.keyCode].physical == 0) {
    return;
  }

  telar_gui_input input = held_keys[event.keyCode];
  input.phase = 3;
  if ([self sendInput:input]) {
    held_keys[event.keyCode] = (telar_gui_input){0};
  }
}

- (void)releasePressedKeys {
  for (NSUInteger index = 0; index < 256; index++) {
    if (held_keys[index].physical != 0) {
      telar_gui_input input = held_keys[index];
      input.phase = 3;
      [self sendInput:input];
      held_keys[index] = (telar_gui_input){0};
    }
  }

}

- (BOOL)resignFirstResponder {
  [self releasePressedKeys];
  return [super resignFirstResponder];
}

- (void)insertText:(id)value replacementRange:(NSRange)range {
  NSString *text =
      [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
  [self unmarkText];
  [self sendText:text kind:1];
}

- (void)setMarkedText:(id)value
        selectedRange:(NSRange)selection
     replacementRange:(NSRange)replacement {
  NSAttributedString *text =
      [value isKindOfClass:NSAttributedString.class]
          ? value
          : [[NSAttributedString alloc] initWithString:value];
  [marked setAttributedString:text];
}

- (void)unmarkText {
  [marked deleteCharactersInRange:NSMakeRange(0, marked.length)];
}

- (BOOL)hasMarkedText {
  return marked.length != 0;
}

- (NSRange)markedRange {
  return marked.length ? NSMakeRange(0, marked.length)
                       : NSMakeRange(NSNotFound, 0);
}

- (NSRange)selectedRange {
  return NSMakeRange(NSNotFound, 0);
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
  return @[];
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                actualRange:
                                                    (NSRangePointer)actual {
  return nil;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  return NSNotFound;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range
                         actualRange:(NSRangePointer)actual {
  return
      [self.window convertRectToScreen:[self convertRect:NSMakeRect(0, 0, 1, 16)
                                                  toView:nil]];
}

- (void)doCommandBySelector:(SEL)selector {
}

@end

int telar_gui_clipboard(const uint8_t *bytes, size_t len) {
  NSString *text = [[NSString alloc] initWithBytes:bytes
                                            length:len
                                          encoding:NSUTF8StringEncoding];
  if (text == nil) {
    return -1;
  }

  [NSPasteboard.generalPasteboard clearContents];
  return [NSPasteboard.generalPasteboard setString:text
                                           forType:NSPasteboardTypeString]
             ? 0
             : -1;
}
