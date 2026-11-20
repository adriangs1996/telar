#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.cli.commands.project_setup;

namespace {

  using telar::testing::check;

  using namespace telar::runtime::cli;

  // `exec ... -- COMMAND` with `count` words after the separator.
  std::vector<std::string> command(std::size_t count) {
    std::vector<std::string> words{"--", "/bin/echo"};

    for (std::size_t index = 1; index < count; ++index) {
      words.push_back(std::to_string(index));
    }

    return words;
  }

  // The command words fill a fixed array: one word past its size is refused, not copied.
  void argumentCap() {
    auto at_limit = command(ExecutionOptions::max_arguments);
    std::vector<char*> pointers;

    for (auto& word : at_limit) {
      pointers.push_back(word.data());
    }

    const auto parsed = ExecutionOptions::parse(pointers);

    check(parsed.argument_count == ExecutionOptions::max_arguments);
    check(parsed.arguments.front() == "/bin/echo" && parsed.arguments.back() == std::to_string(ExecutionOptions::max_arguments - 1));

    auto over = command(ExecutionOptions::max_arguments + 1);

    pointers.clear();
    for (auto& word : over) {
      pointers.push_back(word.data());
    }

    std::string error;

    try {
      ExecutionOptions::parse(pointers);
    } catch (const std::invalid_argument& refused) {
      error = refused.what();
    }

    check(error == "InvalidExecutionArguments", error);
  }

  const telar::testing::Case case_argument_cap{"execution_options.argument_cap", argumentCap};

}
