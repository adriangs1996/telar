export module telar.platform.error;

import std;
import telar.sys.posix;

// Interface: telar_platform/error.cppm
export {
  namespace telar::runtime {

    class SystemError final : public std::exception {
    public:
      inline explicit SystemError(const char* operation, int code = sys::lastError()) noexcept
          : operation_(operation),
            code_(code) {}

      inline const char* what() const noexcept override {
        return operation_;
      }

      inline int code() const noexcept {
        return code_;
      }

    private:
      const char* operation_;
      int code_;
    };

  }
}
