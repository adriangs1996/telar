export module telar.gui.ui.kit.process:host_command;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.foundation.system;

export namespace telar::gui::qt {

  [[tbc::hot_path]] inline void startHostCommand(QProcess& process, const system::CommandLine& command) {
    QStringList arguments;

    arguments.reserve(static_cast<qsizetype>(command.count));
    for (const auto argument : command.arguments()) {
      arguments.append(toQString(argument));
    }

    process.start(toQString(command.executable), arguments, QIODevice::ReadOnly);
  }

}
