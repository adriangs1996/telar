#pragma once

#include "platform/file_drag.hpp"
#include <AppKit/AppKit.h>

namespace telar::gui::platform {

  // What the rows given to a drag are on the pasteboard, one writer for each row and in their
  // order: a test asks a promise among them for its file, as the system does once the row is
  // let go.
  NSArray<id<NSPasteboardWriting>>* writersOf(const FileDrag& drag);

}
