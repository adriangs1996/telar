// The modal that shows an attached image over its pane.
export module telar.gui.features.terminal.attachments:presentation;

import std;

import telar.gui.foundation.core;

// Interface: presentation/attachment_modal_geometry.cppm
export {
  namespace telar::gui::features::terminal::attachments {

    struct AttachmentModalGeometry {
      static constexpr std::uint16_t margin_columns = 8;
      static constexpr std::uint16_t margin_rows = 4;
      static constexpr std::uint16_t minimum_content_rows = 3;

      CellRectangle bounds{};
      CellRectangle title{};
      CellRectangle close{};
      CellRectangle image{};
      CellRectangle footer{};

      [[nodiscard]] static AttachmentModalGeometry measure(CellRectangle host) noexcept;
    };

  }
}
