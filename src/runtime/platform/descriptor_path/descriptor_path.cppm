export module telar.runtime.platform.descriptor_path;

import std;
import telar.sys.posix;
import telar.base.ds;

// Interface: platform/descriptor_path.cppm
export {
  namespace telar::runtime {

    ds::Array<char, PATH_MAX> descriptorPath(int descriptor);

  }
}
