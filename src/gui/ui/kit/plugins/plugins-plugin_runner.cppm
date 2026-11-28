export module telar.gui.ui.kit.plugins:plugin_runner;

import std;
import telar.gui.qt;
import telar.tbc;
import :plugin_worker;
import telar.gui.ui.kit.config;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;

extern "C++" namespace telar::gui::test {
  struct MachineWindow;
  struct ComponentActions;
}

export namespace telar::gui::qt {

  // Runs one plugin at a time on a worker, for the active machine. Its effects apply only while
  // that machine, its runtime and the configuration that started it are still the ones shown;
  // the window applies them.
  class [[qt::object]] PluginRunner final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    PluginRunner(Store& store, ConfigurationSource& configuration, ApplicationAllocator& memory, QObject* parent = nullptr);
    ~PluginRunner() override = default;
    PluginRunner(const PluginRunner&) = delete;
    PluginRunner& operator=(const PluginRunner&) = delete;
    PluginRunner(PluginRunner&&) = delete;
    PluginRunner& operator=(PluginRunner&&) = delete;

    // Starts the plugin; it throws while another one runs.
    void start(const application::plugins::PluginInvocation& invocation);
    [[nodiscard]] bool idle() const;
    // What the worker calls once the plugin finished.
    void pluginWorkerFinished(std::uint64_t execution, const application::plugins::PluginInvocation& invocation, const PluginWorkerResult& result);

    [[qt::signal]] void finished(const telar::gui::application::plugins::PluginEffects& effects);
    [[qt::signal]] void failed(const QString& message);

  private:
    friend struct test::MachineWindow;
    friend struct test::ComponentActions;

    struct Owner {
      application::machines::MachineClientKey source;
      std::uint64_t runtime_generation = 0;
      std::uint64_t execution = 0;
    };

    Store& store_;
    ConfigurationSource& configuration_;
    tbc::val_self<PluginWorker<PluginRunner>> worker_;
    ds::Option<Owner> owner_;
    std::uint64_t next_execution_ = 1;
  };

}
