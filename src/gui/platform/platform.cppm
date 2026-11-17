// The native boundary's C++ half: the clipboard image pipe reads a descriptor the platform's
// clipboard source hands over, and the transfer completes the Objective-C++ ABI's forward
// declaration. Its names stay in telar::gui::platform, where the textual headers beside it
// declare theirs.
export module telar.gui.platform;

export import :clipboard_image_pipe;
export import :clipboard_image_transfer;
