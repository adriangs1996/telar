module;

export module telar.base.editors;

import std;

// Interface: telar_base/editors/kind.cppm
export {
  namespace telar::runtime {

    enum class EditorKind {
      neovim,
      vim,
      emacs,
      unsupported,
    };

    EditorKind identifyEditor(std::string_view path) noexcept;

  }
}
