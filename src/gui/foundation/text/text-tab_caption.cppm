export module telar.gui.foundation.text:tab_caption;

import std;

import telar.tbc;
import telar.base.ds;

// Interface: presentation/tab_caption.cppm
export {
  namespace telar::gui::inline foundation::inline text {

    struct TabCaption {
      static constexpr std::size_t capacity = 128;
      static constexpr std::size_t directory_capacity = 48;
      static constexpr std::string_view separator = " · ";
      static constexpr std::string_view fallback_application = "shell";
      static constexpr std::string_view fullscreen_suffix = " ⛶";
      static constexpr std::string_view path_separators = "/\\";
      using Buffer = ds::Array<char, capacity>;

      struct Content {
        std::string_view manual;
        std::string_view application;
        std::string_view directory;
        std::string_view session_title;
      };

      [[nodiscard]] static std::string_view directoryName(std::string_view path) noexcept;

      // The caption is one of the content's texts or is written into the storage, region `a`.
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> resolve(tbc::view<Content, tbc::lt::a> content, tbc::view<Buffer&, tbc::lt::a> storage) noexcept;
    };

  }
}
