/// Child-controlled modes required to encode semantic keyboard and paste
/// input. The runtime derives these from its VT; the client never guesses.
const InputModes = @This();

cursor_keys: bool = false,
keypad_keys: bool = false,
bracketed_paste: bool = false,
focus_events: bool = false,
alternate_scroll: bool = false,
alternate_screen: bool = false,
kitty_keyboard_flags: u5 = 0,
modify_other_keys_2: bool = false,
