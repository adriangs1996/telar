#include "blur_symbols.h"
#include <dlfcn.h>

TelarGuiBlurSymbols telarGuiBlurSymbols(void) {
  return (TelarGuiBlurSymbols){
      .connection = (TelarGuiBlurConnection)dlsym(RTLD_DEFAULT, "CGSDefaultConnectionForThread"),
      .set_radius = (TelarGuiBlurSetRadius)dlsym(RTLD_DEFAULT, "CGSSetWindowBackgroundBlurRadius"),
  };
}
