# The tree-sitter parsers telar brings its editor for the languages Neovim ships none of, and
# the queries that highlight with them. Each grammar is at the revision nvim-treesitter
# 0195cd62 pins, and each archive by the SHA-256 it must have; the queries are nvim-treesitter's
# of that commit. c, lua, markdown, query, vim and vimdoc are Neovim's own.
#
# telar_nvim_parsers(DIRECTORY dir) builds them into dir/parser, copies the queries to
# dir/queries, and installs both under share/telar/editor, where the runtime finds them beside
# its programs and tells the editor's Neovim to read them.

include(FetchContent)

set(TELAR_NVIM_TREESITTER_URL "https://github.com/nvim-treesitter/nvim-treesitter/archive/0195cd62fa89950f34c0e0d648ea7897ab85d4d3.tar.gz")
set(TELAR_NVIM_TREESITTER_SHA256 "0f7946ac81397ddf6cd802832041e7acc2797b8cb42515264ee3d5b66ccec48f")

# source|archive|SHA-256 of the archive
set(TELAR_NVIM_GRAMMAR_SOURCES
  "bash|https://github.com/tree-sitter/tree-sitter-bash/archive/a06c2e4415e9bc0346c6b86d401879ffb44058f7.tar.gz|879e8951ea2cc82455407e3eda0293319657ec53e83191e0fb5a67430d10d804"
  "cpp|https://github.com/tree-sitter/tree-sitter-cpp/archive/c009222808634c1014f82438d4883753516a2c24.tar.gz|6c6efaf024f5c02fee0403e4e2373346eeadc40828587bcfad9351df2f0a7986"
  "css|https://github.com/tree-sitter/tree-sitter-css/archive/dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f.tar.gz|c47392e483feb9137d8f0acf9ca6e916b820122c260324454a9980c75c98c3c5"
  "diff|https://github.com/tree-sitter-grammars/tree-sitter-diff/archive/ada384ac7bfc1307f32de474620120add29998fb.tar.gz|e11ccb2f6a5bd966170ccba7d160d832e002e64006a101d7339137795158e73b"
  "dockerfile|https://github.com/camdencheek/tree-sitter-dockerfile/archive/971acdd908568b4531b0ba28a445bf0bb720aba5.tar.gz|0263fd719ce93ea663847a49b501052c2b93853e33ffc5e8ddca3a739d7db246"
  "go|https://github.com/tree-sitter/tree-sitter-go/archive/2346a3ab1bb3857b48b29d779a1ef9799a248cd7.tar.gz|94d08fc0f727a8dbe03203e2aaf1c5dc33a57e496b583049324eddc79769797b"
  "html|https://github.com/tree-sitter/tree-sitter-html/archive/73a3947324f6efddf9e17c0ea58d454843590cc0.tar.gz|892f6b732e08bcb90918a985fdee58d6a0fd7a90326af601a2536a5d477583fa"
  "java|https://github.com/tree-sitter/tree-sitter-java/archive/e10607b45ff745f5f876bfa3e94fbcc6b44bdc11.tar.gz|95a46b6b7b545b48cd6c3a0d5b1014fed271a63a71164cdc4382d9d441e3609f"
  "javascript|https://github.com/tree-sitter/tree-sitter-javascript/archive/58404d8cf191d69f2674a8fd507bd5776f46cb11.tar.gz|f3e51e9f7b129f62a817551ae22a878dac5c18d71c456d5ad73e9c82d687f33d"
  "json|https://github.com/tree-sitter/tree-sitter-json/archive/254c42a6476413b776221e03982ac8ae159eeb72.tar.gz|5735ec109268bdc25eb67875b96bc891de1f405253a1d3f9528a504249b0f832"
  "make|https://github.com/tree-sitter-grammars/tree-sitter-make/archive/70613f3d812cbabbd7f38d104d60a409c4008b43.tar.gz|bd60f6d2950086ba5d1d81e0890fc3e4e71e4d276b58b8cc1e1e95c9609ce331"
  "python|https://github.com/tree-sitter/tree-sitter-python/archive/v0.25.0.tar.gz|4609a3665a620e117acf795ff01b9e965880f81745f287a16336f4ca86cf270c"
  "regex|https://github.com/tree-sitter/tree-sitter-regex/archive/b2ac15e27fce703d2f37a79ccd94a5c0cbe9720b.tar.gz|a31267c9190042e4a851f826721f2a5cd2f0df5890a0fc5ff8c4471d853612f4"
  "ruby|https://github.com/tree-sitter/tree-sitter-ruby/archive/ad907a69da0c8a4f7a943a7fe012712208da6dee.tar.gz|f7aa2408f1b39922f85add38cacd60b59828a8222c609a240f08779d46d079d9"
  "rust|https://github.com/tree-sitter/tree-sitter-rust/archive/77a3747266f4d621d0757825e6b11edcbf991ca5.tar.gz|dee82ddfd01bfc3a8ed201cc03b56448107d3217a4b3a7a8fc7fa6bc32b2405b"
  "toml|https://github.com/tree-sitter-grammars/tree-sitter-toml/archive/64b56832c2cffe41758f28e05c756a3a98d16f41.tar.gz|feeb2e1cf531588cdcfb9c57292620151a08597f18a98dad26cc17fd4b544dcb"
  "typescript|https://github.com/tree-sitter/tree-sitter-typescript/archive/75b3874edb2dc714fb1fd77a32013d0f8699989f.tar.gz|96ce4d1b513767d414bcca408efd9b49879162cceecdbed79a88e8ad2184f385"
  "yaml|https://github.com/tree-sitter-grammars/tree-sitter-yaml/archive/a1c4812a73ec5e089de8e441fdea3a921e8d5079.tar.gz|6548cd059983e8073dfa39f102641f71d045b37f3a05b7ebd799ad17df8471d1"
  "zig|https://github.com/tree-sitter-grammars/tree-sitter-zig/archive/6479aa13f32f701c383083d8b28360ebd682fb7d.tar.gz|34b338658c7548ea7e723b9a74a18bba76d16bf453bc4a9deb13f2f507f4e725"
)

# language|source|directory of the grammar in its source
set(TELAR_NVIM_PARSERS
  "bash|bash|." "cpp|cpp|." "css|css|." "diff|diff|." "dockerfile|dockerfile|." "go|go|."
  "html|html|." "java|java|." "javascript|javascript|." "json|json|." "make|make|."
  "python|python|." "regex|regex|." "ruby|ruby|." "rust|rust|." "toml|toml|."
  "typescript|typescript|typescript" "tsx|typescript|tsx" "yaml|yaml|." "zig|zig|."
)

# The queries the languages above read, with the ones they inherit and have no parser of their
# own. Only those Neovim applies by itself: indents.scm is nvim-treesitter's, and needs its
# predicates.
set(TELAR_NVIM_QUERY_LANGUAGES
  bash cpp css diff dockerfile go html html_tags java javascript ecma jsx json make python regex
  ruby rust toml typescript tsx yaml zig)
set(TELAR_NVIM_QUERY_KINDS highlights injections folds)

function(telar_nvim_parsers)
  cmake_parse_arguments(PARSE_ARGV 0 arg "" "DIRECTORY" "")
  set(all_parsers)

  foreach(entry IN LISTS TELAR_NVIM_GRAMMAR_SOURCES)
    string(REPLACE "|" ";" entry "${entry}")
    list(GET entry 0 source)
    list(GET entry 1 url)
    list(GET entry 2 sha256)
    FetchContent_Declare(telar_grammar_${source}
      URL "${url}"
      URL_HASH SHA256=${sha256}
      DOWNLOAD_EXTRACT_TIMESTAMP TRUE
      SOURCE_SUBDIR telar-source-only)
    FetchContent_MakeAvailable(telar_grammar_${source})
  endforeach()

  foreach(entry IN LISTS TELAR_NVIM_PARSERS)
    string(REPLACE "|" ";" entry "${entry}")
    list(GET entry 0 language)
    list(GET entry 1 source)
    list(GET entry 2 location)
    set(grammar "${telar_grammar_${source}_SOURCE_DIR}/${location}/src")
    set(sources "${grammar}/parser.c")
    if(EXISTS "${grammar}/scanner.c")
      list(APPEND sources "${grammar}/scanner.c")
    endif()

    # A module Neovim loads by its name, parser/<language>.so on every system. It links nothing of
    # telar's, so no sanitizer or warning of telar's own code reaches a grammar's generated C.
    set(target telar-nvim-parser-${language})
    add_library(${target} MODULE ${sources})
    target_include_directories(${target} PRIVATE "${grammar}")
    target_compile_options(${target} PRIVATE -w)
    set_target_properties(${target} PROPERTIES
      PREFIX ""
      SUFFIX ".so"
      OUTPUT_NAME "${language}"
      C_STANDARD 11
      C_VISIBILITY_PRESET default
      LINKER_LANGUAGE C
      CXX_MODULE_STD OFF
      LIBRARY_OUTPUT_DIRECTORY "${arg_DIRECTORY}/parser")
    install(TARGETS ${target} LIBRARY DESTINATION share/telar/editor/parser)
    list(APPEND all_parsers ${target})
  endforeach()

  FetchContent_Declare(telar_nvim_treesitter
    URL "${TELAR_NVIM_TREESITTER_URL}"
    URL_HASH SHA256=${TELAR_NVIM_TREESITTER_SHA256}
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_SUBDIR telar-source-only)
  FetchContent_MakeAvailable(telar_nvim_treesitter)

  foreach(language IN LISTS TELAR_NVIM_QUERY_LANGUAGES)
    foreach(kind IN LISTS TELAR_NVIM_QUERY_KINDS)
      set(query "${telar_nvim_treesitter_SOURCE_DIR}/runtime/queries/${language}/${kind}.scm")
      if(EXISTS "${query}")
        file(COPY "${query}" DESTINATION "${arg_DIRECTORY}/queries/${language}")
      endif()
    endforeach()
  endforeach()

  install(DIRECTORY "${arg_DIRECTORY}/queries" DESTINATION share/telar/editor)

  # Each grammar's license, and nvim-treesitter's for the queries.
  foreach(entry IN LISTS TELAR_NVIM_GRAMMAR_SOURCES)
    string(REPLACE "|" ";" entry "${entry}")
    list(GET entry 0 source)
    install(FILES "${telar_grammar_${source}_SOURCE_DIR}/LICENSE" DESTINATION share/telar/licenses/editor/tree-sitter-${source})
  endforeach()

  install(FILES "${telar_nvim_treesitter_SOURCE_DIR}/LICENSE" DESTINATION share/telar/licenses/editor/nvim-treesitter)
  add_custom_target(nvim-parsers DEPENDS ${all_parsers})
endfunction()
