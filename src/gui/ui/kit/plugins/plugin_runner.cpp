module telar.gui.ui.kit.plugins;

import std;
import telar.gui.foundation.system;

namespace telar::gui::qt {

  PluginRunner::PluginRunner(Store& store, ConfigurationSource& configuration, ApplicationAllocator& memory, QObject* parent)
      : QObject(parent),
        store_(store),
        configuration_(configuration),
        worker_(memory, *this) {}

  bool PluginRunner::idle() const {
    return !worker_.active() && !owner_;
  }

  void PluginRunner::start(const application::plugins::PluginInvocation& invocation) {
    if (!idle()) {
      throw std::runtime_error{"PluginWorkerBusy"};
    }

    if (next_execution_ == 0) {
      throw std::runtime_error{"PluginExecutionIdExhausted"};
    }

    const auto& client = store_.client(store_.machines().active());
    const auto execution = next_execution_++;

    owner_ = Owner{.source = client.key, .runtime_generation = client.runtime_generation, .execution = execution};
    try {
      const auto program = system::runtime_endpoint::program();

      worker_.start(invocation, execution, QString::fromUtf8(program.view().data(), static_cast<qsizetype>(program.view().size())));
    } catch (...) {
      owner_.reset();
      throw;
    }
  }

  void PluginRunner::pluginWorkerFinished(std::uint64_t execution, const application::plugins::PluginInvocation& invocation, const PluginWorkerResult& result) {
    if (!owner_ || owner_->execution != execution) {
      return;
    }

    const auto owner = *owner_;

    owner_.reset();
    const auto* client = store_.find(owner.source);
    if (client == nullptr || client->key.machine.slot != store_.machines().active() || client->runtime_generation != owner.runtime_generation || !client->connection.ready() || configuration_.configurationGeneration() != invocation.configuration_generation) {
      return;
    }

    try {
      if (!result.error.isEmpty()) {
        throw std::runtime_error{result.error.toStdString()};
      }

      if (!result.effects) {
        throw std::runtime_error{"PluginWorkerFailed"};
      }

      configuration_.authorizePlugin(invocation, *result.effects);
      finished(*result.effects);
    } catch (const std::exception& error) {
      failed(QString::fromUtf8(error.what()));
    }
  }

}
