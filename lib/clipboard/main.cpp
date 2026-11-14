// The command line lives in cli.cpp, which the macOS tests link without this entry point.
namespace telar::clipboard {
  int runCli(int argc, char** argv);
}

int main(int argc, char** argv) {
  return telar::clipboard::runCli(argc, argv);
}
