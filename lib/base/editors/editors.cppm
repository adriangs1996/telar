module;

export module telar.base.editors;

import std;

// Interface: telar_base/editors/kind.cppm
export {
  namespace telar::runtime {

    enum class EditorKind : std::uint8_t {
      neovim,
      vim,
      emacs,
      unsupported,
    };

    EditorKind identifyEditor(std::string_view path) noexcept;

  }
}
