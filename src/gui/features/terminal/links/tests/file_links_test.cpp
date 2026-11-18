#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <cstring>

import std;
import telar.testing;
import telar.gui.features.terminal.links;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar::gui;
  using namespace telar::gui::features::terminal::links;

  template <typename Operation>
  void requireFailure(Operation operation, std::string_view expected) {
    try {
      operation();
    } catch (const std::exception& error) {
      check(error.what() == expected, "operation must report its specific failure");

      return;
    }

    throw std::runtime_error{"Expected file-link failure did not occur"};
  }

  FilePath filePath(std::string_view text) {
    const auto target = LinkTarget::fromUri(text);
    if (!target) {
      throw std::runtime_error{"Fixture URI must classify before file decoding"};
    }

    return FilePath::parse(*target);
  }

  struct Environment {
    telar::ds::Option<std::string_view> home = "/home/reader";

    [[nodiscard]] telar::ds::Option<std::string_view> operator()(std::string_view name) const noexcept {
      if (name == "HOME") {
        return home;
      }

      if (name == "PROJECT") {
        return "telar";
      }

      return name == "EMPTY" ? telar::ds::Option{std::string_view{}} : telar::ds::none;
    }
  };

  void fileDecoding() {
    const auto path = filePath("file://LOCAL%68ost/tmp/a%20b/%E4%B8%AD.cpp#L12C3-L20");
    constexpr std::uint32_t line = 12;
    constexpr std::uint32_t column = 3;

    check(path.text() == "/tmp/a b/中.cpp" && path.line() == line && path.column() == column, "local file links must decode paths and retain the first fragment position");
    const auto root = filePath("file:/#0C3");

    check(root.text() == "/" && root.line() == 0 && root.column() == 0, "column zeroing must follow a zero line");
    const auto prose = LinkTarget::fromPath("../src/main.cpp:12:3");
    if (!prose) {
      throw std::runtime_error{"Relative path fixture must be valid"};
    }

    const auto relative = FilePath::parse(*prose);

    check(relative.text() == "../src/main.cpp" && relative.line() == line && relative.column() == column, "prose positions must remain separate from the path");

    constexpr auto invalid = std::to_array<std::string_view>({"file:/tmp/%", "file:/tmp/%xy", "file:/tmp/%00", "file:/tmp/a?query", "file://user@localhost/a", "file://localhost:3/a", "file:/tmp/a#section"});

    for (const auto uri : invalid) {
      requireFailure([&] {
        static_cast<void>(filePath(uri));
      },
          "InvalidFileLink");
    }

    requireFailure([] {
      static_cast<void>(filePath("file://remote.test/a"));
    },
        "RemoteFileLink");
    const auto web = LinkTarget::fromUri("https://example.test/a");

    check(web.hasValue(), "web fixture must classify");
    requireFailure([&] {
      static_cast<void>(FilePath::parse(*web));
    },
        "NotFileLink");
  }

  void pathAnchoring() {
    const Environment environment;
    const auto expanded = PathExpansion::expand({.text = " ~/sandbox/$PROJECT/../${PROJECT}/./file.cpp ", .base = "/unused"}, environment);

    check(expanded.view() == "/home/reader/sandbox/telar/file.cpp", "home, variable and lexical segment expansion must compose without filesystem access");
    check(PathExpansion::expand({.text = "../../../../x//", .base = "/work/project"}, environment).view() == "/x", "parent traversal must stop at the absolute root");
    check(PathExpansion::expand({.text = "$EMPTY", .base = "/work/project"}, environment).view() == "/work/project", "an empty environment value must remain distinct from a missing variable");
    check(PathExpansion::expand({.text = "$?/${}/$", .base = "/work"}, environment).view() == "/work/$?/${}/$", "dollar bytes without variable names must remain literal");
    requireFailure([&] {
      static_cast<void>(PathExpansion::expand({.text = "$MISSING", .base = "/work"}, environment));
    },
        "UnknownVariable");
    requireFailure([&] {
      static_cast<void>(PathExpansion::expand({.text = "${PROJECT", .base = "/work"}, environment));
    },
        "UnterminatedVariable");
    requireFailure([&] {
      static_cast<void>(PathExpansion::expand({.text = "relative", .base = {}}, environment));
    },
        "BaseUnavailable");
    requireFailure([] {
      static_cast<void>(PathExpansion::expand({.text = "~/file", .base = "/work"}, Environment{.home = telar::ds::none}));
    },
        "HomeUnavailable");
    const std::string oversized(PathExpansion::maximum_bytes, 'x');

    requireFailure([&] {
      static_cast<void>(PathExpansion::expand({.text = oversized, .base = "/work"}, environment));
    },
        "PathTooLong");
  }

  void editorArguments() {
    constexpr std::string_view path = "/tmp/a $(id); '中'.cpp";
    constexpr std::uint32_t line = 12;
    constexpr std::uint32_t column = 3;
    EditorLaunch launch;
    auto arguments = launch.arguments("/usr/bin/nvim", path, line, column);

    check(arguments.size() == 3 && arguments[1] == "+call cursor(12, 3)" && arguments[2] == path, "Neovim must receive a literal path and cursor expression as separate arguments");
    arguments = launch.arguments("vim.nox", path, line, 0);
    check(arguments.size() == 3 && arguments[1] == "+12" && arguments[2] == path, "Vim variants must preserve the plus-line convention");
    arguments = launch.arguments("emacsclient", path, line, column);
    check(arguments[1] == "+12:3" && arguments[2] == path, "Emacs must receive colon-separated coordinates");
    arguments = launch.arguments("nano", path, line, column);
    check(arguments[1] == "+12,3", "nano must receive comma-separated coordinates");
    arguments = launch.arguments("helix", path, line, column);
    check(arguments.size() == 2 && arguments[1] == std::string{path} + ":12:3", "Helix must receive a positioned path as one argument");
    arguments = launch.arguments("code-insiders", path, line, column);
    check(arguments.size() == 3 && arguments[1] == "-g" && arguments[2] == std::string{path} + ":12:3", "VS Code variants must receive a goto flag and one positioned path");
    arguments = launch.arguments("unknown-editor", path, line, column);
    check(arguments.size() == 2 && arguments[1] == path, "unknown editors must open the literal path without inventing coordinate flags");
    arguments = launch.arguments("nvim", path, 0, column);
    check(arguments.size() == 2 && arguments[1] == path, "line zero must disable every coordinate convention");
    constexpr auto maximum = std::numeric_limits<std::uint32_t>::max();

    arguments = launch.arguments("nvim", path, maximum, maximum);
    check(arguments[1] == "+call cursor(4294967295, 4294967295)", "position formatting must preserve the full wire coordinate range");
  }

  void ownedEditorRequest() {
    std::string editor = "nvim";
    std::string path = "/tmp/original.cpp";
    const EditorTarget target{editor, path, 0, 0};

    editor.assign("different");
    path.assign("/changed");
    State opening;
    const EditorRequest request{.request_id = 1, .source = {.pane_id = 2, .pane_generation = 3}, .target = target};

    static_cast<void>(open(opening, request));
    requireFailure([&] {
      static_cast<void>(open(opening, request));
    },
        "EditorOpenBusy");
    check(!complete(opening, 2) && pending(opening, 1), "an unrelated reply must not consume a pending editor request");
    const auto completed = complete(opening, 1);

    check(completed && completed->message().editor == "nvim" && completed->message().path == "/tmp/original.cpp", "pending editor requests must own both strings independently of their producers");
    check(!complete(opening, 1), "duplicate editor replies must not complete an operation twice");
    static_cast<void>(open(opening, request));
    suspend(opening);
    check(!pending(opening, 1), "disconnect must release pending editor authority");
    requireFailure([] {
      static_cast<void>(EditorTarget{"-unsafe", "/tmp/a", 0, 0});
    },
        "InvalidEditorTarget");
    requireFailure([] {
      static_cast<void>(EditorTarget{"nvim", "relative", 0, 0});
    },
        "InvalidEditorTarget");
  }

  const telar::testing::Case case_file_decoding{"file_links.file_decoding", fileDecoding};
  const telar::testing::Case case_path_anchoring{"file_links.path_anchoring", pathAnchoring};
  const telar::testing::Case case_editor_arguments{"file_links.editor_arguments", editorArguments};
  const telar::testing::Case case_owned_editor_request{"file_links.owned_editor_request", ownedEditorRequest};

}
