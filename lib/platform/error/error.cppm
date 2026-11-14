export module telar.platform.error;

import std;
import telar.sys.posix;

// Interface: telar_platform/error.cppm
export {
  namespace telar::runtime {

    class SystemError final : public std::exception {
    public:
      explicit SystemError(const char* operation, int code = sys::lastError()) noexcept;

      const char* what() const noexcept override;
      int code() const noexcept;

    private:
      const char* operation_;
      int code_;
    };

  }
}
