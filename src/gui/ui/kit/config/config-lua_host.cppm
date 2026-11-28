export module telar.gui.ui.kit.config:lua_host;

import std;
import telar.gui.qt;
import telar.base.ds;

export namespace telar::gui::qt {

  template <typename Value>
  struct LuaOutcome {
    ds::Option<Value> value;
    QString error;
    // The configuration that ran the call was replaced before its result arrived.
    bool stale = false;
  };

  template <>
  struct LuaOutcome<void> {
    bool done = false;
    QString error;
    bool stale = false;
  };

  // Runs every call into one client VM on a single thread, in submission order, so a slow
  // or runaway Lua function delays other Lua work instead of the window.
  class LuaHost final : public QObject {
  public:
    explicit LuaHost(QObject* parent = nullptr);
    ~LuaHost() override;
    LuaHost(const LuaHost&) = delete;
    LuaHost& operator=(const LuaHost&) = delete;
    LuaHost(LuaHost&&) = delete;
    LuaHost& operator=(LuaHost&&) = delete;

    // `work` runs on the Lua thread; `done` runs on this object's thread with its outcome.
    template <typename Work, typename Done>
    [[tbc::generic]] void post(Work work, Done done) {
      using Value = std::invoke_result_t<Work&>;

      struct Task {
        Work work;
        Done done;
        LuaOutcome<Value> outcome;
      };

      auto task = std::make_shared<Task>(Task{.work = std::move(work), .done = std::move(done), .outcome = {}});

      ++pending_;
      QMetaObject::invokeMethod(worker_, [this, job = std::move(task)] mutable {
        try {
          if constexpr (std::is_void_v<Value>) {
            job->work();
            job->outcome.done = true;
          } else {
            job->outcome.value.emplace(job->work());
          }
        } catch (const std::exception& error) {
          job->outcome.error = QString::fromUtf8(error.what());
        }

        // The window thread owns `this`; its destructor waits for this thread first.
        QMetaObject::invokeMethod(this, [this, job] mutable {
          --pending_;
          job->done(std::move(job->outcome));
        },
            Qt::QueuedConnection);
      },
          Qt::QueuedConnection);
    }

    [[tbc::hot_path]] [[nodiscard]] inline bool idle() const noexcept {
      return pending_ == 0;
    }

  private:
    QThread thread_;
    QObject* worker_ = nullptr;
    std::size_t pending_ = 0;
  };

}
