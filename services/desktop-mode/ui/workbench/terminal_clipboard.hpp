#pragma once

#include "runtime_connection.hpp"
#include "terminal_item.hpp"

namespace workbench {

inline void bindClipboardPaste(TerminalItem &item, RuntimeConnection &runtime, std::uint64_t pane) {
  item.paste = [connection = QPointer<RuntimeConnection>{&runtime}, pane](bool listing_only) {
    if (connection) {
      connection->paste(pane, listing_only);
    }
  };
}

}
