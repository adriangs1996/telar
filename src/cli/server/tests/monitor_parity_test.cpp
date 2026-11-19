import std;
import telar.testing;
import telar.cli.server;
import telar.wire.monitor;

namespace {

  using telar::testing::check;

  // Every monitor operation the window offers has its command in the CLI, with its help.
  void testEveryOperationHasItsCommand() {
    for (const auto& operation : telar::monitor_operations) {
      const auto text = telar::runtime::cli::helpText({.family = operation.family, .command = operation.command});

      check(text.hasValue() && !text->empty(), std::string{operation.binding});
    }
  }

  const telar::testing::Case case_every_operation{"monitor_parity.every_operation_has_its_command", testEveryOperationHasItsCommand};

}
