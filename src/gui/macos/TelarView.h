#pragma once
#import "TelarTextInputView.h"
@class TelarWindowBackground;

@interface TelarView : TelarTextInputView <NSWindowDelegate>
@property(nonatomic, weak) TelarWindowBackground *backgroundView;
- (instancetype)initWithFrame:(NSRect)frame
                      context:(void *)render_context
                    callbacks:(const telar_gui_callbacks *)callback_table;
- (void)startWakeSource;
@end
