module;
#include <cerrno>

export module telar.platform.error;

import std;

// Interface: telar_platform/error.cppm
export {
  namespace telar::runtime {

    class SystemError final : public std::exception {
    public:
      inline explicit SystemError(const char* operation, int code = errno) noexcept
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

    // The name the CLI prints for an errno, a token scripts read after `error: `. Every errno a
    // command can meet on files and sockets has one; anything else is Unexpected.
    inline const char* systemErrorName(int code) noexcept {
      switch (code) {
      case ENOENT:
        return "FileNotFound";
      case ECONNREFUSED:
        return "ConnectionRefused";
      case EACCES:
      case EPERM:
        return "AccessDenied";
      case ENOTDIR:
        return "NotDir";
      case ENAMETOOLONG:
        return "NameTooLong";
      case ELOOP:
        return "SymLinkLoop";
      case EEXIST:
        return "PathAlreadyExists";
      case ENOSPC:
        return "NoSpaceLeft";
      case EINVAL:
        return "InvalidArgument";
      case EIO:
        return "InputOutput";
      default:
        return "Unexpected";
      }
    }

  }
}
