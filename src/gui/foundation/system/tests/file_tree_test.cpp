#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdlib>
#include <unistd.h>

import std;
import telar.testing;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.gui.foundation.system;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using telar::testing::check;

  struct Tree {
    std::filesystem::path root;

    Tree() {
      std::string pattern = (std::filesystem::temp_directory_path() / "telar-file-tree-XXXXXX").string();

      check(::mkdtemp(pattern.data()) != nullptr, "temporary directory");
      root = std::filesystem::canonical(pattern);
    }

    ~Tree() {
      std::error_code ignored;

      std::filesystem::remove_all(root, ignored);
    }

    Tree(const Tree&) = delete;
    Tree& operator=(const Tree&) = delete;
    Tree(Tree&&) = delete;
    Tree& operator=(Tree&&) = delete;

    void write(const std::string& path, const std::string& text) const {
      std::filesystem::create_directories((root / path).parent_path());
      std::ofstream{root / path} << text;
    }
  };

  // What a read took, by path.
  std::map<std::string, std::string> taken(const ds::Vec<FileTreeFile, Memory>& files) {
    std::map<std::string, std::string> result;

    for (const auto& file : files) {
      result.emplace(std::string{file.path.view()}, std::string{file.content.view().begin(), file.content.view().end()});
    }

    return result;
  }

  // A tree's files come by their path from it; what starts with a dot stays, and a link is read as
  // what it points at.
  void readsTheFilesOfATree() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    const Tree tree;
    const Tree outside;
    ds::Vec<FileTreeFile, Memory> files{memory};

    tree.write("init.lua", "require('plugins')\n");
    tree.write("lua/plugins/ui.lua", "return {}\n");
    tree.write(".git/HEAD", "ref: refs/heads/main\n");
    tree.write("lua/.hidden.lua", "--\n");
    outside.write("shared.lua", "-- elsewhere\n");
    std::filesystem::create_symlink(outside.root / "shared.lua", tree.root / "lua/shared.lua");
    std::filesystem::create_symlink(tree.root / "missing", tree.root / "dangling.lua");

    check(readFileTree(memory, tree.root.native(), {.files = 16, .bytes = 1024, .depth = 8}, files) == FileTreeRead::read, "the tree is read");
    const std::map<std::string, std::string> expected{{"init.lua", "require('plugins')\n"}, {"lua/plugins/ui.lua", "return {}\n"}, {"lua/shared.lua", "-- elsewhere\n"}};

    check(taken(files) == expected, "its files by their paths, dot entries and dangling links left out");
    check(readFileTree(memory, (tree.root / "nothing").native(), {.files = 16, .bytes = 1024, .depth = 8}, files) == FileTreeRead::absent && files.empty(), "a directory that is not there is absent");
    check(readFileTree(memory, tree.root.native(), {.files = 2, .bytes = 1024, .depth = 8}, files) == FileTreeRead::too_large && files.empty(), "more files than the limit is too large");
    check(readFileTree(memory, tree.root.native(), {.files = 16, .bytes = 20, .depth = 8}, files) == FileTreeRead::too_large, "more bytes than the limit is too large");
    check(readFileTree(memory, tree.root.native(), {.files = 16, .bytes = 1024, .depth = 2}, files) == FileTreeRead::too_large, "deeper than the limit is too large");
  }

  const telar::testing::Case case_tree{"file_tree.reads_the_files_of_a_tree", readsTheFilesOfATree};

}
