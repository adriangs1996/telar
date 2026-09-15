#import "TelarTextInputView.h"
#import "text_ranges.h"
#include <math.h>

@implementation TelarTextInputView {
  TelarInputHandler input_handler;
  NSMutableAttributedString *marked;
  uint32_t text_phase, text_physical;
  telar_gui_text_context text_context;
  NSString *surrounding;
  NSRange selection_range, marked_selection, marked_replacement;
  BOOL optimistic_committed_text;
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
  surrounding = @"";
  selection_range = NSMakeRange(0, 0);
  marked_replacement = NSMakeRange(NSNotFound, 0);
  return self;
}

- (void)stopInput {
  input_handler = nil;
  [marked deleteCharactersInRange:NSMakeRange(0, marked.length)];
  surrounding = @"";
  text_context = (telar_gui_text_context){0};
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

- (int)copyTextContext:(telar_gui_text_context *)output {
  (void)output;
  return NO;
}

- (void)refreshTextContext {
  telar_gui_text_context next = {0};
  int status = [self copyTextContext:&next];
  if (status < 0) return;
  if (status == 0) next = (telar_gui_text_context){0};
  if (next.len > TELAR_GUI_TEXT_CAPACITY || (next.len && next.text == NULL) ||
      !isfinite(next.x) || !isfinite(next.y) || !isfinite(next.width) || !isfinite(next.height)) return;
  BOOL changed_owner = next.target_id != text_context.target_id || next.generation != text_context.generation || next.enabled != text_context.enabled;
  if (changed_owner || (next.enabled && !next.composition_active && marked.length)) {
    [marked deleteCharactersInRange:NSMakeRange(0, marked.length)];
    marked_replacement = NSMakeRange(NSNotFound, 0);
    [self.inputContext discardMarkedText];
  }
  if (!changed_owner && next.revision == text_context.revision && !optimistic_committed_text) {
    text_context.x = next.x;
    text_context.y = next.y;
    text_context.width = next.width;
    text_context.height = next.height;
    return;
  }
  NSString *text = next.len ? [[NSString alloc] initWithBytes:next.text length:next.len encoding:NSUTF8StringEncoding] : @"";
  NSRange selected = telar_utf16_range(text, next.selection_start, next.selection_end);
  if (text == nil || (next.enabled && selected.location == NSNotFound)) return;
  surrounding = text;
  selection_range = selected.location == NSNotFound ? NSMakeRange(0, 0) : selected;
  text_context = next;
  text_context.text = NULL;
  optimistic_committed_text = NO;
  if (marked.length && (marked_replacement.location > surrounding.length || marked_replacement.length > surrounding.length - marked_replacement.location)) {
    [marked deleteCharactersInRange:NSMakeRange(0, marked.length)];
    marked_replacement = NSMakeRange(NSNotFound, 0);
  }
  [self.inputContext invalidateCharacterCoordinates];
}

- (NSRange)committedRange:(NSRange)range {
  if (range.location == NSNotFound) return range;
  NSUInteger document_length = surrounding.length;
  if (marked.length && marked_replacement.location != NSNotFound) document_length = document_length - marked_replacement.length + marked.length;
  if (range.location > document_length || range.length > document_length - range.location) return NSMakeRange(NSNotFound, 0);
  if (!marked.length || marked_replacement.location == NSNotFound) return range;
  NSUInteger mark_start = marked_replacement.location, mark_end = mark_start + marked.length;
  if (range.length > NSUIntegerMax - range.location) return NSMakeRange(NSNotFound, 0);
  NSUInteger first = range.location, last = NSMaxRange(range);
  if (first > mark_start) first = first >= mark_end ? first - marked.length + marked_replacement.length : mark_start;
  if (last > mark_start) last = last >= mark_end ? last - marked.length + marked_replacement.length : NSMaxRange(marked_replacement);
  return NSMakeRange(first, last - first);
}

- (NSString *)inputDocument {
  if (!marked.length || marked_replacement.location == NSNotFound) return surrounding;
  return [surrounding stringByReplacingCharactersInRange:marked_replacement withString:marked.string];
}

- (void)sendText:(NSString *)text kind:(uint32_t)kind replacement:(NSRange)replacement {
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil || data.length > 64 * 1024) return;
  const BOOL scalar = text.length == 1 ||
      (text.length == 2 && CFStringIsSurrogateHighCharacter([text characterAtIndex:0]) &&
       CFStringIsSurrogateLowCharacter([text characterAtIndex:1]));
  uint32_t physical = kind == 1 && scalar && marked.length == 0 ? text_physical : 0;
  telar_gui_input event = {.kind = kind, .phase = kind == 1 && physical != 0 ? text_phase : 1,
      .text = data.bytes, .len = data.length, .physical = physical,
      .target_id = text_context.enabled ? text_context.target_id : 0,
      .generation = text_context.generation,
      .replacement_start = TELAR_GUI_RANGE_NONE, .replacement_end = TELAR_GUI_RANGE_NONE};
  NSRange committed = [self committedRange:replacement];
  if (replacement.location != NSNotFound && committed.location == NSNotFound) return;
  if (committed.location != NSNotFound && !telar_utf8_range(surrounding, committed, &event.replacement_start, &event.replacement_end)) return;
  if (![self sendInput:event]) return;
  if (physical != 0 && physical <= 256) {
    uint32_t code = text.length == 1 ? [text characterAtIndex:0] :
        CFStringGetLongCharacterForSurrogatePair([text characterAtIndex:0], [text characterAtIndex:1]);
    held_keys[physical - 1] = (telar_gui_input){.kind = 4, .code = code, .physical = physical, .phase = 1,
        .target_id = event.target_id, .generation = event.generation};
  }
  if (kind == 1) {
    optimistic_committed_text = text_context.enabled;
    NSRange replace = committed.location != NSNotFound ? committed : marked.length ? marked_replacement : selection_range;
    if (text_context.enabled && replace.location <= surrounding.length && replace.length <= surrounding.length - replace.location &&
        surrounding.length - replace.length + text.length <= TELAR_GUI_TEXT_CAPACITY) {
      surrounding = [surrounding stringByReplacingCharactersInRange:replace withString:text];
      selection_range = NSMakeRange(replace.location + text.length, 0);
    }
    [marked deleteCharactersInRange:NSMakeRange(0, marked.length)];
    marked_replacement = NSMakeRange(NSNotFound, 0);
  }
}

- (void)paste:(id)sender {
  (void)sender;
  [self sendInput:(telar_gui_input){.kind = 4, .code = 'v', .mods = 8, .phase = 1,
      .target_id = text_context.enabled ? text_context.target_id : 0, .generation = text_context.generation}];
}

- (void)keyDown:(NSEvent *)event {
  [self refreshTextContext];
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
  if (marked.length && !(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl))) {
    text_physical = 0;
    [self interpretKeyEvents:@[event]];
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
                  ((event.modifierFlags & NSEventModifierFlagControl) ? 4 : 0) |
                  ((event.modifierFlags & NSEventModifierFlagCommand) ? 8 : 0);
  if (code != 0) {
    telar_gui_input input = {.kind = 3,
                             .code = code,
                             .mods = mods,
                             .phase = event.isARepeat ? 2 : 1,
                             .physical = text_physical,
                             .target_id = text_context.enabled ? text_context.target_id : 0,
                             .generation = text_context.generation};
    if ([self sendInput:input] && input.physical != 0) {
      held_keys[input.physical - 1] = input;
    }
  } else if (mods & (2 | 4 | 8)) {
    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length == 1) {
      telar_gui_input input = {.kind = 4,
                               .code = [characters characterAtIndex:0],
                               .mods = mods,
                               .phase = event.isARepeat ? 2 : 1,
                             .physical = text_physical,
                             .target_id = text_context.enabled ? text_context.target_id : 0,
                             .generation = text_context.generation};
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
  NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
  [self sendText:text kind:1 replacement:range];
}

- (void)setMarkedText:(id)value selectedRange:(NSRange)selection replacementRange:(NSRange)replacement {
  NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil || data.length > TELAR_GUI_TEXT_CAPACITY) return;
  if (data.length == 0) {
    [self cancelMarkedText];
    return;
  }
  telar_gui_input event = {.kind = 7, .code = 1, .phase = 1, .text = data.bytes, .len = data.length,
      .target_id = text_context.enabled ? text_context.target_id : 0, .generation = text_context.generation,
      .replacement_start = TELAR_GUI_RANGE_NONE, .replacement_end = TELAR_GUI_RANGE_NONE};
  if (!telar_utf8_range(text, selection, &event.selection_start, &event.selection_end)) return;
  NSRange committed = [self committedRange:replacement];
  if (replacement.location != NSNotFound && committed.location == NSNotFound) return;
  if (committed.location != NSNotFound && !telar_utf8_range(surrounding, committed, &event.replacement_start, &event.replacement_end)) return;
  // A terminal exposes no editable surrounding text. AppKit still needs its
  // provisional buffer to complete an IME transaction before committing text.
  if (text_context.enabled && ![self sendInput:event]) return;
  if (committed.location != NSNotFound) marked_replacement = committed;
  else if (!marked.length) marked_replacement = selection_range;
  [marked setAttributedString:[[NSAttributedString alloc] initWithString:text]];
  marked_selection = selection;
}

- (void)unmarkText {
  if (marked.length) [self sendText:[marked.string copy] kind:1 replacement:NSMakeRange(NSNotFound, 0)];
}

- (void)cancelMarkedText {
  if (!marked.length) return;
  if (text_context.enabled && ![self sendInput:(telar_gui_input){.kind = 7, .code = 2, .phase = 1,
      .target_id = text_context.enabled ? text_context.target_id : 0, .generation = text_context.generation,
      .replacement_start = TELAR_GUI_RANGE_NONE, .replacement_end = TELAR_GUI_RANGE_NONE}]) return;
  [marked deleteCharactersInRange:NSMakeRange(0, marked.length)];
  marked_replacement = NSMakeRange(NSNotFound, 0);
}

- (BOOL)hasMarkedText { return marked.length != 0; }

- (NSRange)markedRange {
  return marked.length ? NSMakeRange(marked_replacement.location, marked.length) : NSMakeRange(NSNotFound, 0);
}

- (NSRange)selectedRange {
  return marked.length ? NSMakeRange(marked_replacement.location + marked_selection.location, marked_selection.length) : selection_range;
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual {
  NSString *document = [self inputDocument];
  if (range.location == NSNotFound || range.location > document.length) return nil;
  range.length = MIN(range.length, document.length - range.location);
  if (actual != NULL) *actual = range;
  return [[NSAttributedString alloc] initWithString:[document substringWithRange:range]];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  NSRect caret = [self firstRectForCharacterRange:[self selectedRange] actualRange:NULL];
  return NSPointInRect(point, NSInsetRect(caret, -2, -2)) ? [self selectedRange].location : NSNotFound;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
  if (actual != NULL) *actual = [self selectedRange];
  NSRect caret = text_context.enabled ? telar_content_rect(self, text_context.x, text_context.y, text_context.width, text_context.height) : NSMakeRect(0, 0, 1, 16);
  return [self.window convertRectToScreen:[self convertRect:caret toView:nil]];
}

- (void)doCommandBySelector:(SEL)selector {
  if (selector == @selector(cancelOperation:) && marked.length) {
    [self cancelMarkedText];
    return;
  }
  uint32_t code = selector == @selector(insertNewline:) ? 1 : selector == @selector(insertTab:) ? 2 :
      selector == @selector(deleteBackward:) ? 3 : selector == @selector(cancelOperation:) ? 4 :
      selector == @selector(moveUp:) ? 5 : selector == @selector(moveDown:) ? 6 :
      selector == @selector(moveLeft:) ? 7 : selector == @selector(moveRight:) ? 8 : 0;
  if (code) [self sendInput:(telar_gui_input){.kind = 3, .code = code, .phase = 1,
      .target_id = text_context.enabled ? text_context.target_id : 0, .generation = text_context.generation}];
}

@end
