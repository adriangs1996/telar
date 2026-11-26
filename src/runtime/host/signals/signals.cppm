export module telar.runtime.host.signals;

import std;

import telar.platform.primitives;

// Interface: platform/completion_signal.cppm
export {
  namespace telar::runtime {

    // A pipe one thread notifies and another drains: both ends share it.
    class [[tbc::shared]] CompletionSignal {
    public:
      CompletionSignal();

      void notify() noexcept;

      void drain() noexcept;

      bool consume() noexcept;

      [[nodiscard]] int descriptor() const noexcept;

    private:
      FileDescriptor reader_;
      FileDescriptor writer_;
    };

  }
}

// Interface: platform/cancellation_signal.cppm
export {
  namespace telar::runtime {

    // Any thread may request cancellation and any may observe it: the flag is atomic and the wake signal
    // is shared, so a reference to it stays valid whatever is done through it.
    class [[tbc::shared]] CancellationSignal {
    public:
      void request() noexcept;

      bool requested() const noexcept;

      int descriptor() const noexcept;

    private:
      CompletionSignal wake_;
      std::atomic<bool> requested_{false};
    };

  }
}
