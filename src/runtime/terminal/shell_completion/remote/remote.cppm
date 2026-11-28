export module telar.runtime.terminal.shell_completion.remote;

import std;

import telar.wire.vocabulary;

// How a pane `ssh` reached completes on its host: through the connection the pane's session
// shares, with a command that is the runtime's own and data that only standard input carries.
export namespace telar::runtime::remote_completion {

  // The host's answer starts after this byte: what the login shell's own startup printed goes
  // before it.
  inline constexpr char answer_start = '\x1d';

  // The command ssh runs on the host for `shell`'s words, or for the entries of a directory with
  // `IntegratedShell::none`. Fixed code: /bin/sh decodes and runs remote.sh with the shell's
  // completion script; ssh appends the question and `rc`, the runtime's own words.
  std::string_view command(IntegratedShell shell) noexcept;

  // The question remote.sh reads for a shell's words.
  std::string_view question(IntegratedShell shell) noexcept;

  // Whether the socket a pane's shell named may carry the line to the host: a socket of the
  // user's, in the runtime's private directory or in a directory nobody else may write, where
  // the user's own ssh_config keeps theirs. Anywhere else it could be another user's, who would
  // read every line. A symbolic link is no socket.
  bool acceptedControl(std::string_view socket, std::string_view private_directory) noexcept;

}
