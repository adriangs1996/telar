#import "TelarAccessibility.h"
#import "text_ranges.h"
#include <math.h>

@class TelarAccessibilityNode;
@interface TelarAccessibility ()
- (BOOL)send:(telar_gui_input)event;
@end

@interface TelarAccessibilityNode : NSAccessibilityElement
@property(nonatomic, weak) TelarAccessibility *bridge;
@property(nonatomic, weak) NSView *view;
@property(nonatomic, weak) id semanticParent;
@property(nonatomic, strong) NSArray *semanticChildren;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *value;
@property(nonatomic) telar_gui_accessibility_node node;
@property(nonatomic) BOOL active;
@end

@implementation TelarAccessibilityNode
- (BOOL)isAccessibilityElement { return self.active; }
- (id)accessibilityParent { return self.semanticParent; }
- (NSArray *)accessibilityChildren { return self.semanticChildren; }
- (NSString *)accessibilityLabel { return self.label; }
- (id)accessibilityValue { return self.node.role == 5 ? @((self.node.flags & 4) != 0) : self.value; }
- (BOOL)isAccessibilityEnabled { return self.active && (self.node.flags & 1) != 0; }
- (BOOL)isAccessibilityFocused { return self.active && (self.node.flags & 2) != 0; }
- (BOOL)isAccessibilitySelected { return (self.node.flags & 4) != 0; }
- (BOOL)isAccessibilityModal { return (self.node.flags & 32) != 0; }
- (NSInteger)accessibilityNumberOfCharacters { return self.value.length; }
- (NSAccessibilityRole)accessibilityRole {
  switch (self.node.role) {
    case 2: return NSAccessibilityButtonRole;
    case 3: return (self.node.flags & 16) ? NSAccessibilityTextAreaRole : NSAccessibilityTextFieldRole;
    case 4: return NSAccessibilityStaticTextRole;
    case 5: return NSAccessibilityRadioButtonRole;
    case 6: return NSAccessibilityListRole;
    case 7: return NSAccessibilityRowRole;
    case 8: return NSAccessibilityTextAreaRole;
    default: return NSAccessibilityGroupRole;
  }
}
- (NSRect)accessibilityFrame {
  NSView *view = self.view;
  NSRect rect = telar_content_rect(view, self.node.x, self.node.y, self.node.width, self.node.height);
  return [view.window convertRectToScreen:[view convertRect:rect toView:nil]];
}
- (NSRange)accessibilitySelectedTextRange {
  return telar_utf16_range(self.value, self.node.selection_start, self.node.selection_end);
}
- (NSString *)accessibilitySelectedText {
  NSRange range = [self accessibilitySelectedTextRange];
  return range.location == NSNotFound ? @"" : [self.value substringWithRange:range];
}
- (NSString *)accessibilityStringForRange:(NSRange)range {
  if (range.location > self.value.length || range.length > self.value.length - range.location) return nil;
  return [self.value substringWithRange:range];
}
- (BOOL)dispatchAction:(uint32_t)action text:(NSData *)text selection:(NSRange)selection {
  if (!self.active || !(self.node.flags & 1) || !(self.node.actions & action)) return NO;
  telar_gui_input event = {.kind = 10, .code = action, .phase = 1,
      .target_id = self.node.id, .generation = self.node.generation, .revision = self.node.text_revision,
      .text = text.bytes, .len = text.length};
  if (action == 8 && !telar_utf8_range(self.value, selection, &event.selection_start, &event.selection_end)) return NO;
  return [self.bridge send:event];
}
- (BOOL)accessibilityPerformPress { return [self dispatchAction:1 text:nil selection:NSMakeRange(0, 0)]; }
- (BOOL)accessibilityPerformIncrement { return [self dispatchAction:16 text:nil selection:NSMakeRange(0, 0)]; }
- (BOOL)accessibilityPerformDecrement { return [self dispatchAction:32 text:nil selection:NSMakeRange(0, 0)]; }
- (void)setAccessibilityFocused:(BOOL)focused {
  if (focused) [self dispatchAction:2 text:nil selection:NSMakeRange(0, 0)];
}
- (void)setAccessibilityValue:(id)value {
  if (![value isKindOfClass:NSString.class] || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > TELAR_GUI_TEXT_CAPACITY) return;
  NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
  if (bytes != nil) [self dispatchAction:4 text:bytes selection:NSMakeRange(0, 0)];
}
- (void)setAccessibilitySelectedTextRange:(NSRange)range {
  [self dispatchAction:8 text:nil selection:range];
}
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
  if (selector == @selector(accessibilityPerformPress)) return (self.node.actions & 1) != 0;
  if (selector == @selector(setAccessibilityFocused:)) return (self.node.actions & 2) != 0;
  if (selector == @selector(setAccessibilityValue:)) return (self.node.actions & 4) != 0;
  if (selector == @selector(setAccessibilitySelectedTextRange:)) return (self.node.actions & 8) != 0;
  if (selector == @selector(accessibilityPerformIncrement)) return (self.node.actions & 16) != 0;
  if (selector == @selector(accessibilityPerformDecrement)) return (self.node.actions & 32) != 0;
  return [super isAccessibilitySelectorAllowed:selector];
}
@end

@implementation TelarAccessibility {
  __weak NSView *view;
  void *context;
  telar_gui_callbacks callbacks;
  NSDictionary<NSNumber *, TelarAccessibilityNode *> *elements;
  NSArray *roots;
  uint64_t revision;
  BOOL initialized, closed;
}

- (instancetype)initWithView:(NSView *)owner context:(void *)value callbacks:(const telar_gui_callbacks *)table {
  self = [super init];
  if (self != nil) {
    view = owner;
    context = value;
    callbacks = *table;
    roots = @[];
    elements = @{};
  }
  return self;
}

- (BOOL)send:(telar_gui_input)event {
  return !closed && callbacks.input != NULL && callbacks.input(context, event) != 0;
}

static BOOL valid_tree(telar_gui_accessibility_tree tree) {
  if (tree.count > TELAR_GUI_ACCESSIBILITY_CAPACITY || (tree.count && tree.nodes == NULL)) return NO;
  for (uint32_t index = 0; index < tree.count; index++) {
    const telar_gui_accessibility_node *node = &tree.nodes[index];
    if (!node->id || node->role < 1 || node->role > 8 || node->label_len > TELAR_GUI_TEXT_CAPACITY || node->value_len > TELAR_GUI_TEXT_CAPACITY ||
        (node->label_len && node->label == NULL) || (node->value_len && node->value == NULL) ||
        !isfinite(node->x) || !isfinite(node->y) || !isfinite(node->width) || !isfinite(node->height) || node->width < 0 || node->height < 0) return NO;
    for (uint32_t other = 0; other < index; other++) if (tree.nodes[other].id == node->id) return NO;
    uint64_t parent = node->parent_id;
    for (uint32_t depth = 0; parent; depth++) {
      if (depth >= tree.count || parent == node->id) return NO;
      BOOL found = NO;
      for (uint32_t other = 0; other < tree.count; other++) if (tree.nodes[other].id == parent) {
        parent = tree.nodes[other].parent_id;
        found = YES;
        break;
      }
      if (!found) return NO;
    }
  }
  return YES;
}

- (void)refresh {
  if (closed || callbacks.accessibility == NULL) return;
  telar_gui_accessibility_tree tree = {0};
  if (!callbacks.accessibility(context, &tree)) tree = (telar_gui_accessibility_tree){0};
  if (initialized && tree.revision == revision && tree.count == elements.count) return;
  if (!valid_tree(tree)) return;
  NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithCapacity:tree.count];
  NSMutableArray<NSString *> *values = [NSMutableArray arrayWithCapacity:tree.count];
  for (uint32_t index = 0; index < tree.count; index++) {
    const telar_gui_accessibility_node *node = &tree.nodes[index];
    NSString *label = node->label_len ? [[NSString alloc] initWithBytes:node->label length:node->label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *value = node->value_len ? [[NSString alloc] initWithBytes:node->value length:node->value_len encoding:NSUTF8StringEncoding] : @"";
    if (label == nil || value == nil) return;
    [labels addObject:label];
    [values addObject:value];
  }
  id previous_focus = [self focusedElement];
  NSMutableArray *changed_values = [NSMutableArray array];
  NSMutableArray *changed_selections = [NSMutableArray array];
  NSMutableDictionary<NSNumber *, TelarAccessibilityNode *> *replacement = [NSMutableDictionary dictionaryWithCapacity:tree.count];
  for (uint32_t index = 0; index < tree.count; index++) {
    telar_gui_accessibility_node value = tree.nodes[index];
    NSNumber *key = @(value.id);
    TelarAccessibilityNode *element = elements[key];
    if (element != nil && element.node.generation != value.generation) {
      element.active = NO;
      element = nil;
    }
    if (element != nil) {
      if (![element.value isEqualToString:values[index]] || ((element.node.flags ^ value.flags) & 4)) [changed_values addObject:element];
      if (element.node.selection_start != value.selection_start || element.node.selection_end != value.selection_end) [changed_selections addObject:element];
    } else element = [TelarAccessibilityNode new];
    element.bridge = self;
    element.view = view;
    element.active = YES;
    element.label = labels[index];
    element.value = values[index];
    value.label = value.value = NULL;
    element.node = value;
    element.semanticChildren = @[];
    replacement[key] = element;
  }
  NSMutableArray *top = [NSMutableArray array];
  for (uint32_t index = 0; index < tree.count; index++) {
    TelarAccessibilityNode *element = replacement[@(tree.nodes[index].id)];
    TelarAccessibilityNode *parent = replacement[@(element.node.parent_id)];
    element.semanticParent = parent != nil ? parent : view;
    NSRect rect = telar_content_rect(view, element.node.x, element.node.y, element.node.width, element.node.height);
    if (parent != nil) {
      NSRect parent_rect = telar_content_rect(view, parent.node.x, parent.node.y, parent.node.width, parent.node.height);
      rect.origin.x -= parent_rect.origin.x;
      rect.origin.y -= parent_rect.origin.y;
      parent.semanticChildren = [parent.semanticChildren arrayByAddingObject:element];
    } else [top addObject:element];
    element.accessibilityFrameInParentSpace = rect;
  }
  for (NSNumber *key in elements) if (replacement[key] != elements[key]) elements[key].active = NO;
  elements = replacement;
  roots = top;
  revision = tree.revision;
  initialized = YES;
  NSAccessibilityPostNotification(view, NSAccessibilityLayoutChangedNotification);
  for (id element in changed_values) NSAccessibilityPostNotification(element, NSAccessibilityValueChangedNotification);
  for (id element in changed_selections) NSAccessibilityPostNotification(element, NSAccessibilitySelectedTextChangedNotification);
  id focused = [self focusedElement];
  if (focused != nil && focused != previous_focus) NSAccessibilityPostNotification(focused, NSAccessibilityFocusedUIElementChangedNotification);
}

- (NSArray *)children { return roots; }
- (id)focusedElement {
  for (TelarAccessibilityNode *element in elements.objectEnumerator) if (element.isAccessibilityFocused) return element;
  return nil;
}
static id node_at(TelarAccessibilityNode *element, NSPoint point) {
  if (!element.active || !NSPointInRect(point, element.accessibilityFrame)) return nil;
  for (TelarAccessibilityNode *child in element.semanticChildren.reverseObjectEnumerator) {
    id found = node_at(child, point);
    if (found != nil) return found;
  }
  return element;
}

- (id)hitTest:(NSPoint)point {
  for (TelarAccessibilityNode *element in roots.reverseObjectEnumerator) {
    id found = node_at(element, point);
    if (found != nil) return found;
  }
  return nil;
}
- (void)stop {
  closed = YES;
  for (TelarAccessibilityNode *element in elements.objectEnumerator) element.active = NO;
  elements = @{};
  roots = @[];
  context = NULL;
  callbacks = (telar_gui_callbacks){0};
}
@end
