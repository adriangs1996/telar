module telar.vocabulary;

namespace telar::runtime {

  RequestError::RequestError(FailureCode code, const char* message) noexcept
      : code_(code),
        message_(message) {}

  FailureCode RequestError::code() const noexcept {
    return code_;
  }

  const char* RequestError::what() const noexcept {
    return message_;
  }

}
