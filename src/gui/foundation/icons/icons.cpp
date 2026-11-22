module telar.gui.foundation.icons;

import std;
import telar.base.ds;

namespace telar::gui::inline foundation::inline icons {

  namespace {

    struct Entry {
      std::string_view key;
      GlyphIcon icon;
    };

    constexpr Entry entry(std::string_view key, char32_t glyph, IconTone tone) noexcept {
      return {.key = key, .icon = {.glyph = glyph, .tone = tone}};
    }

    // The icons of mini.icons (MIT, Evgeni Chasnovski) for the names and the extensions most
    // projects hold, with its colors as roles of the window's palette. Each table is sorted by
    // its key, lower case, for a binary search.
    constexpr ds::Array<Entry, 59> files{
        entry(".bashrc", 0xF0493, IconTone::green),
        entry(".clang-format", 0xE6A8, IconTone::mauve),
        entry(".clang-tidy", 0xE6A8, IconTone::mauve),
        entry(".clangd", 0xE6A8, IconTone::mauve),
        entry(".editorconfig", 0xE652, IconTone::grey),
        entry(".env", 0xF0214, IconTone::grey),
        entry(".envrc", 0xE691, IconTone::grey),
        entry(".eslintrc.json", 0xF0626, IconTone::yellow),
        entry(".gitattributes", 0xF02A2, IconTone::yellow),
        entry(".gitconfig", 0xF0493, IconTone::peach),
        entry(".gitignore", 0xF02A2, IconTone::mauve),
        entry(".gitmodules", 0xF0493, IconTone::peach),
        entry(".npmrc", 0xF0BC2, IconTone::blue),
        entry(".nvmrc", 0xF0493, IconTone::green),
        entry(".prettierrc", 0xF0626, IconTone::yellow),
        entry(".vimrc", 0xE7C5, IconTone::green),
        entry(".zshrc", 0xF0493, IconTone::green),
        entry("agents.md", 0xF0354, IconTone::grey),
        entry("brewfile", 0xF0D2D, IconTone::red),
        entry("build.zig", 0xE6A9, IconTone::peach),
        entry("build.zig.zon", 0xE6A9, IconTone::peach),
        entry("cargo.lock", 0xE6B2, IconTone::peach),
        entry("cargo.toml", 0xE6B2, IconTone::peach),
        entry("changelog.md", 0xF027B, IconTone::blue),
        entry("claude.md", 0xF0354, IconTone::grey),
        entry("cmakelists.txt", 0xF1064, IconTone::peach),
        entry("compose.yaml", 0xE6A8, IconTone::mauve),
        entry("containerfile", 0xF0868, IconTone::blue),
        entry("contributing.md", 0xF0EBE, IconTone::blue),
        entry("deno.json", 0xF0626, IconTone::yellow),
        entry("docker-compose.yml", 0xE6A8, IconTone::mauve),
        entry("dockerfile", 0xF0868, IconTone::blue),
        entry("flake.lock", 0xF0626, IconTone::yellow),
        entry("flake.nix", 0xF1105, IconTone::blue),
        entry("gemfile", 0xF0D2D, IconTone::red),
        entry("gnumakefile", 0xF1064, IconTone::grey),
        entry("go.mod", 0xF0AFA, IconTone::teal),
        entry("go.sum", 0xF07D3, IconTone::teal),
        entry("init.lua", 0xF36F, IconTone::green),
        entry("justfile", 0xF05B7, IconTone::peach),
        entry("license", 0xE60A, IconTone::teal),
        entry("license.md", 0xE60A, IconTone::teal),
        entry("makefile", 0xF1064, IconTone::grey),
        entry("mix.exs", 0xE653, IconTone::mauve),
        entry("package-lock.json", 0xF0626, IconTone::yellow),
        entry("package.json", 0xF0626, IconTone::yellow),
        entry("pipfile", 0xE6B2, IconTone::peach),
        entry("pnpm-lock.yaml", 0xE6A8, IconTone::mauve),
        entry("pyproject.toml", 0xE6B2, IconTone::peach),
        entry("rakefile", 0xF0D2D, IconTone::red),
        entry("readme", 0xF4ED, IconTone::yellow),
        entry("readme.md", 0xF4ED, IconTone::yellow),
        entry("rebar.config", 0xE7B1, IconTone::red),
        entry("requirements.txt", 0xF160E, IconTone::mauve),
        entry("setup.py", 0xF0320, IconTone::yellow),
        entry("stack.yaml", 0xE6A8, IconTone::mauve),
        entry("tsconfig.json", 0xF0626, IconTone::yellow),
        entry("vagrantfile", 0xF0D2D, IconTone::red),
        entry("yarn.lock", 0xE6A8, IconTone::mauve),
    };

    constexpr ds::Array<Entry, 183> extensions{
        entry("7z", 0xF05C4, IconTone::blue),
        entry("a", 0xE637, IconTone::mauve),
        entry("adoc", 0xF0AB6, IconTone::yellow),
        entry("ai", 0xE7B4, IconTone::yellow),
        entry("astro", 0xE6B3, IconTone::peach),
        entry("avi", 0xF022B, IconTone::grey),
        entry("awk", 0xE691, IconTone::grey),
        entry("bash", 0xE691, IconTone::grey),
        entry("bat", 0xF0BC2, IconTone::green),
        entry("bazel", 0xE63A, IconTone::green),
        entry("bib", 0xF125F, IconTone::yellow),
        entry("bmp", 0xF021F, IconTone::green),
        entry("bz2", 0xF05C4, IconTone::peach),
        entry("bzl", 0xE63A, IconTone::green),
        entry("c", 0xF0671, IconTone::blue),
        entry("cc", 0xF0672, IconTone::blue),
        entry("cfg", 0xF0493, IconTone::blue),
        entry("cjs", 0xF031E, IconTone::yellow),
        entry("clj", 0xE768, IconTone::green),
        entry("cljc", 0xE768, IconTone::green),
        entry("cljs", 0xE768, IconTone::green),
        entry("cmake", 0xF1064, IconTone::peach),
        entry("cmd", 0xF0BC2, IconTone::green),
        entry("conf", 0xF0493, IconTone::grey),
        entry("cpp", 0xF0672, IconTone::blue),
        entry("cppm", 0xF0672, IconTone::blue),
        entry("crt", 0xF0307, IconTone::yellow),
        entry("cs", 0xF031B, IconTone::green),
        entry("css", 0xF031C, IconTone::blue),
        entry("csv", 0xE64A, IconTone::green),
        entry("cts", 0xF06E6, IconTone::blue),
        entry("cxx", 0xF0672, IconTone::blue),
        entry("d", 0xE7AF, IconTone::green),
        entry("dart", 0xE798, IconTone::blue),
        entry("diff", 0xF0993, IconTone::red),
        entry("dockerfile", 0xF0868, IconTone::blue),
        entry("edn", 0xE768, IconTone::green),
        entry("eex", 0xE62D, IconTone::yellow),
        entry("el", 0xE6B0, IconTone::grey),
        entry("elm", 0xE62C, IconTone::blue),
        entry("env", 0xF0214, IconTone::grey),
        entry("eps", 0xE7B4, IconTone::red),
        entry("erb", 0xF0D2D, IconTone::peach),
        entry("erl", 0xE7B1, IconTone::red),
        entry("ex", 0xE62D, IconTone::mauve),
        entry("exe", 0xF05B3, IconTone::red),
        entry("exs", 0xE653, IconTone::mauve),
        entry("fish", 0xE691, IconTone::grey),
        entry("flac", 0xF0223, IconTone::peach),
        entry("fnl", 0xE6AF, IconTone::yellow),
        entry("fs", 0xE7A7, IconTone::blue),
        entry("fsx", 0xE7A7, IconTone::blue),
        entry("gemspec", 0xF0D2D, IconTone::red),
        entry("gif", 0xF0D78, IconTone::blue),
        entry("go", 0xF07D3, IconTone::blue),
        entry("gql", 0xF0877, IconTone::red),
        entry("gradle", 0xE775, IconTone::blue),
        entry("graphql", 0xF0877, IconTone::red),
        entry("groovy", 0xE775, IconTone::blue),
        entry("gz", 0xF05C4, IconTone::grey),
        entry("h", 0xF0AF5, IconTone::mauve),
        entry("hcl", 0xF0AF5, IconTone::blue),
        entry("heex", 0xE62D, IconTone::red),
        entry("hh", 0xF0672, IconTone::blue),
        entry("hpp", 0xF0672, IconTone::blue),
        entry("hrl", 0xE7B1, IconTone::red),
        entry("hs", 0xF0C92, IconTone::mauve),
        entry("htm", 0xF031D, IconTone::peach),
        entry("html", 0xF031D, IconTone::peach),
        entry("hxx", 0xF0672, IconTone::blue),
        entry("ini", 0xF0BC2, IconTone::blue),
        entry("inl", 0xF0672, IconTone::blue),
        entry("ipp", 0xF0672, IconTone::blue),
        entry("ipynb", 0xF082E, IconTone::peach),
        entry("ixx", 0xF0672, IconTone::blue),
        entry("janet", 0xF0AF7, IconTone::peach),
        entry("java", 0xF0B37, IconTone::peach),
        entry("jl", 0xE624, IconTone::mauve),
        entry("jpeg", 0xF0225, IconTone::peach),
        entry("jpg", 0xF0225, IconTone::peach),
        entry("js", 0xF031E, IconTone::yellow),
        entry("json", 0xF0626, IconTone::yellow),
        entry("json5", 0xF0626, IconTone::peach),
        entry("jsonc", 0xF0626, IconTone::yellow),
        entry("jsx", 0xE625, IconTone::blue),
        entry("just", 0xF05B7, IconTone::peach),
        entry("kt", 0xF1219, IconTone::blue),
        entry("kts", 0xF1219, IconTone::blue),
        entry("less", 0xF031C, IconTone::mauve),
        entry("lhs", 0xE61F, IconTone::mauve),
        entry("lisp", 0xE6B0, IconTone::grey),
        entry("lua", 0xF08B1, IconTone::blue),
        entry("luau", 0xF08B1, IconTone::green),
        entry("m", 0xF0FC8, IconTone::peach),
        entry("m4a", 0xF0223, IconTone::mauve),
        entry("markdown", 0xF0354, IconTone::grey),
        entry("md", 0xF0354, IconTone::grey),
        entry("mjs", 0xF031E, IconTone::yellow),
        entry("mk", 0xF1064, IconTone::grey),
        entry("mkv", 0xF022B, IconTone::green),
        entry("ml", 0xE67A, IconTone::peach),
        entry("mli", 0xE67A, IconTone::peach),
        entry("mm", 0xF0AFB, IconTone::teal),
        entry("mov", 0xF022B, IconTone::teal),
        entry("mp3", 0xF0223, IconTone::blue),
        entry("mp4", 0xF022B, IconTone::blue),
        entry("mpp", 0xF0672, IconTone::blue),
        entry("mts", 0xF06E6, IconTone::blue),
        entry("nim", 0xE677, IconTone::yellow),
        entry("ninja", 0xF0774, IconTone::grey),
        entry("nix", 0xF1105, IconTone::blue),
        entry("nu", 0xE691, IconTone::mauve),
        entry("odin", 0xF0B94, IconTone::blue),
        entry("ogg", 0xF0223, IconTone::grey),
        entry("org", 0xE633, IconTone::teal),
        entry("patch", 0xF0993, IconTone::red),
        entry("pdf", 0xF0226, IconTone::red),
        entry("pem", 0xF0307, IconTone::yellow),
        entry("php", 0xF031F, IconTone::mauve),
        entry("pl", 0xE67E, IconTone::blue),
        entry("pm", 0xE67E, IconTone::blue),
        entry("png", 0xF0E2D, IconTone::mauve),
        entry("prisma", 0xE684, IconTone::blue),
        entry("proto", 0xF1A0, IconTone::red),
        entry("ps1", 0xF0A0A, IconTone::blue),
        entry("purs", 0xE630, IconTone::grey),
        entry("py", 0xF0320, IconTone::yellow),
        entry("pyi", 0xF0320, IconTone::yellow),
        entry("pyx", 0xF0AFD, IconTone::yellow),
        entry("r", 0xF07D4, IconTone::blue),
        entry("rake", 0xF0D2D, IconTone::red),
        entry("rar", 0xF05C4, IconTone::green),
        entry("rb", 0xF0D2D, IconTone::red),
        entry("res", 0xF0AFF, IconTone::blue),
        entry("rkt", 0xF0627, IconTone::red),
        entry("rmd", 0xF0354, IconTone::blue),
        entry("rpm", 0xF05C4, IconTone::red),
        entry("rs", 0xF1617, IconTone::peach),
        entry("rst", 0xF0284, IconTone::yellow),
        entry("ru", 0xF0D2D, IconTone::red),
        entry("sass", 0xF07EC, IconTone::red),
        entry("sc", 0xE737, IconTone::red),
        entry("scala", 0xE737, IconTone::red),
        entry("scm", 0xF0627, IconTone::grey),
        entry("scss", 0xF07EC, IconTone::red),
        entry("sed", 0xF07E5, IconTone::red),
        entry("sh", 0xE691, IconTone::grey),
        entry("sql", 0xF01BC, IconTone::grey),
        entry("star", 0xE63A, IconTone::red),
        entry("styl", 0xF0D12, IconTone::grey),
        entry("svelte", 0xE697, IconTone::peach),
        entry("svg", 0xF0721, IconTone::yellow),
        entry("swift", 0xF06E5, IconTone::peach),
        entry("t", 0xF1A7C, IconTone::blue),
        entry("tar", 0xF05C4, IconTone::teal),
        entry("tex", 0xE69B, IconTone::green),
        entry("tf", 0xF1062, IconTone::blue),
        entry("tfvars", 0xF1062, IconTone::blue),
        entry("tgz", 0xF05C4, IconTone::grey),
        entry("tiff", 0xF021F, IconTone::yellow),
        entry("toml", 0xE6B2, IconTone::peach),
        entry("ts", 0xF06E6, IconTone::blue),
        entry("tsv", 0xE64A, IconTone::blue),
        entry("tsx", 0xE7BA, IconTone::blue),
        entry("txt", 0xF09AA, IconTone::yellow),
        entry("v", 0xE6AC, IconTone::blue),
        entry("vb", 0xF06E4, IconTone::mauve),
        entry("vim", 0xE7C5, IconTone::green),
        entry("vue", 0xF0844, IconTone::green),
        entry("wav", 0xF0223, IconTone::green),
        entry("webm", 0xF022B, IconTone::grey),
        entry("webp", 0xF021F, IconTone::blue),
        entry("xhtml", 0xF031D, IconTone::peach),
        entry("xml", 0xF05C0, IconTone::peach),
        entry("xsd", 0xF05C0, IconTone::yellow),
        entry("xz", 0xF05C4, IconTone::green),
        entry("yaml", 0xE6A8, IconTone::mauve),
        entry("yml", 0xE6A8, IconTone::mauve),
        entry("zig", 0xE6A9, IconTone::peach),
        entry("zip", 0xF05C4, IconTone::blue),
        entry("zon", 0xE6A9, IconTone::peach),
        entry("zsh", 0xE691, IconTone::green),
        entry("zst", 0xF05C4, IconTone::yellow),
    };

    constexpr ds::Array<Entry, 34> kinds{
        entry("array", 0xEA8A, IconTone::peach),
        entry("boolean", 0xEA8F, IconTone::peach),
        entry("class", 0xEB5B, IconTone::mauve),
        entry("color", 0xEB5C, IconTone::red),
        entry("constant", 0xEB5D, IconTone::peach),
        entry("constructor", 0xEAF8, IconTone::blue),
        entry("enum", 0xEA95, IconTone::mauve),
        entry("enummember", 0xEB5E, IconTone::yellow),
        entry("event", 0xEA86, IconTone::red),
        entry("field", 0xEB5F, IconTone::yellow),
        entry("file", 0xEB60, IconTone::blue),
        entry("folder", 0xEA83, IconTone::blue),
        entry("function", 0xEABE, IconTone::blue),
        entry("interface", 0xEB61, IconTone::mauve),
        entry("key", 0xEB11, IconTone::yellow),
        entry("keyword", 0xEB62, IconTone::teal),
        entry("method", 0xEA8C, IconTone::blue),
        entry("module", 0xEA8B, IconTone::mauve),
        entry("namespace", 0xEA8B, IconTone::red),
        entry("null", 0xEABD, IconTone::grey),
        entry("number", 0xEA90, IconTone::peach),
        entry("object", 0xEABC, IconTone::grey),
        entry("operator", 0xEB64, IconTone::teal),
        entry("package", 0xEB29, IconTone::mauve),
        entry("property", 0xEB65, IconTone::yellow),
        entry("reference", 0xEB36, IconTone::teal),
        entry("snippet", 0xEB66, IconTone::green),
        entry("string", 0xEB8D, IconTone::green),
        entry("struct", 0xEA91, IconTone::mauve),
        entry("text", 0xEA93, IconTone::green),
        entry("typeparameter", 0xEA92, IconTone::teal),
        entry("unit", 0xEA96, IconTone::teal),
        entry("value", 0xEAAC, IconTone::blue),
        entry("variable", 0xEA88, IconTone::teal),
    };

    constexpr GlyphIcon file_icon{.glyph = 0xF0214, .tone = IconTone::grey};
    constexpr GlyphIcon directory_icon{.glyph = 0xF024B, .tone = IconTone::blue};

    // The longest key a table holds, and so the longest a lookup needs to lower.
    constexpr std::size_t longest_key = 24;

    template <std::size_t Count>
    consteval bool sorted(const ds::Array<Entry, Count>& table) {
      for (std::size_t index = 1; index < Count; ++index) {
        if (!(table[index - 1].key < table[index].key) || table[index].key.size() > longest_key) {
          return false;
        }
      }

      return true;
    }

    static_assert(sorted(files) && sorted(extensions) && sorted(kinds), "an icon table is sorted, without twice the same key");

    // The entry of `key`, lowered, in `table`; none when it has none.
    template <std::size_t Count>
    ds::Option<GlyphIcon> find(const ds::Array<Entry, Count>& table, std::string_view key) noexcept {
      if (key.empty() || key.size() > longest_key) {
        return ds::none;
      }

      ds::Array<char, longest_key> lowered{};

      for (std::size_t index = 0; index < key.size(); ++index) {
        const auto letter = key[index];

        lowered.atMut(index) = letter >= 'A' && letter <= 'Z' ? static_cast<char>(letter - 'A' + 'a') : letter;
      }

      const std::string_view wanted{lowered.data(), key.size()};
      const auto entries = table.view();
      const auto found = std::ranges::lower_bound(entries, wanted, {}, &Entry::key);
      if (found == entries.end() || found->key != wanted) {
        return ds::none;
      }

      return found->icon;
    }

  }

  GlyphIcon fileIcon(std::string_view name) noexcept {
    auto base = name;

    // After the last slash; a name without one is all of it, as npos and one is zero.
    base.remove_prefix(name.find_last_of('/') + 1);
    if (const auto known = find(files, base)) {
      return *known;
    }

    // The longest extension first: `tar.gz` before `gz`. A name that only starts with a dot
    // has none.
    for (auto dot = base.find('.', 1); dot != std::string_view::npos; dot = base.find('.', dot + 1)) {
      auto extension = base;

      extension.remove_prefix(dot + 1);
      if (const auto known = find(extensions, extension)) {
        return *known;
      }
    }

    return file_icon;
  }

  GlyphIcon directoryIcon() noexcept {
    return directory_icon;
  }

  GlyphIcon kindIcon(std::string_view kind) noexcept {
    // Vim's own completion says a kind in one letter.
    if (kind.size() == 1) {
      switch (kind.front()) {
      case 'v':
        return *find(kinds, "variable");
      case 'f':
        return *find(kinds, "function");
      case 'm':
        return *find(kinds, "field");
      case 't':
        return *find(kinds, "struct");
      case 'd':
        return *find(kinds, "constant");
      default:
        break;
      }
    }

    return find(kinds, kind).valueOr(*find(kinds, "text"));
  }

  std::string_view toneName(IconTone tone) noexcept {
    switch (tone) {
    case IconTone::blue:
      return "blue";
    case IconTone::teal:
      return "teal";
    case IconTone::green:
      return "green";
    case IconTone::grey:
      return "overlay1";
    case IconTone::peach:
      return "peach";
    case IconTone::mauve:
      return "mauve";
    case IconTone::red:
      return "red";
    case IconTone::yellow:
      return "yellow";
    }

    return "subtext0";
  }

  std::span<const GlyphIcon> everyIcon() noexcept {
    static constexpr auto all = [] {
      ds::Array<GlyphIcon, 278> icons{};
      std::size_t count = 0;

      for (const auto table : {files.view().first(files.size()), extensions.view().first(extensions.size()), kinds.view().first(kinds.size())}) {
        for (const auto& known : table) {
          icons.atMut(count++) = known.icon;
        }
      }

      icons.atMut(count++) = file_icon;
      icons.atMut(count) = directory_icon;
      return icons;
    }();

    return all.view();
  }

}
