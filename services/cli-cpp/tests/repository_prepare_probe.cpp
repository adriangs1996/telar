#include "../repository_prepare.hpp"

int main(int argc, char **argv) {
  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::cli;

  if (argc != 2) {
    return 2;
  }

  SystemAllocator system;
  constexpr std::size_t memory_budget = std::size_t{512} * 1024 * 1024;
  BudgetAllocator memory{system, memory_budget};
  const std::string_view binary = argv[1];
  try {
    const RepositoryOptions options{.action = RepositoryOptions::Action::prepare};
    const auto prepared = repository::prepare(memory, options, binary, [&](std::span<const std::string_view> words, int descriptor) {
      if (::lseek(descriptor, 0, SEEK_CUR) != 0) {
        throw std::runtime_error{"BundleWasNotRewound"};
      }

      std::vector<std::string_view> arguments{binary};
      arguments.insert(arguments.end(), words.begin(), words.end());
      Command command{memory, Launch{.arguments = arguments}, CommandPurpose::configured_helper};
      const repository::MappedBundle bundle{descriptor};
      const std::array input{bundle.text()};
      constexpr std::size_t max_reply = 4 * 1024 * 1024;
      CommandOutput output{memory, max_reply};
      const auto status = output.runWithInputDiagnostics(command, std::chrono::steady_clock::now() + repository::git_timeout, input, [](std::span<const Byte> bytes) {
        writeBytes(STDERR_FILENO, bytes);
        return true;
      });
      if (status != 0 || output.truncated()) {
        throw std::runtime_error{"RepositoryTransferFailed"};
      }

      return std::string{output.text()};
    });
    writeText(prepared.json());
    return 0;
  } catch (const std::exception &error) {
    writeText("telar repository: " + std::string{error.what()} + "\n", STDERR_FILENO);
    return 1;
  }
}
