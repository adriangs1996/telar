#pragma once
#import "TelarTextInputView.h"

@interface TelarView : TelarTextInputView <NSWindowDelegate>
- (instancetype)initWithFrame:(NSRect)frame
                      context:(void *)render_context
                    callbacks:(const telar_gui_callbacks *)callback_table;
- (void)startWakeSource;
@end
