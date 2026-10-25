#pragma once

#include <string_view>

namespace telar::runtime {

enum class EditorKind {
  neovim,
  vim,
  emacs,
  unsupported
};

inline EditorKind identifyEditor(std::string_view path) noexcept {
  const auto slash = path.rfind('/');
  const auto name = path.substr(slash == std::string_view::npos ? 0 : slash + 1);
  if (name == "nvim") {
    return EditorKind::neovim;
  }
  if (name == "vi" || name == "vim" || name.starts_with("vim.")) {
    return EditorKind::vim;
  }
  if (name == "emacs" || name == "Emacs" || name == "emacsclient" || name.starts_with("emacs-")) {
    return EditorKind::emacs;
  }
  return EditorKind::unsupported;
}

}
