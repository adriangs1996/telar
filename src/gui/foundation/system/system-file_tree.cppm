// The regular files below a directory, each by its path from it and its bytes, for a copy of the
// directory to be made elsewhere.
export module telar.gui.foundation.system:file_tree;

import std;

import telar.base.ds;
import telar.base.memory.allocators;
import telar.vocabulary;

export {
  namespace telar::gui::inline foundation::inline system {

    // How much of a tree a read takes: past any of them it stops and says the tree is too large.
    struct FileTreeLimits {
      std::size_t files = 0;
      std::size_t bytes = 0;
      std::size_t depth = 0;
    };

    struct FileTreeFile {
      FileTreeFile(Memory& memory, std::string_view name);

      // From the tree's directory, its names joined by '/'.
      ds::String<Memory> path;
      ds::Vec<Byte, Memory> content;
    };

    enum class FileTreeRead : std::uint8_t {
      read,
      // The directory is not there.
      absent,
      // It holds more than the limits let a read take.
      too_large,
    };

    // Reads the regular files below `directory` into `files`, in no order. What starts with a dot
    // is left out, so a checkout's .git is not taken, and a link is read as what it points at.
    // A file that cannot be read, or one that changes while it is, throws SystemError.
    FileTreeRead readFileTree(Memory& memory, std::string_view directory, FileTreeLimits limits, ds::Vec<FileTreeFile, Memory>& files);

  }
}
