#ifndef CHIKVDF_VERSION_HPP
#define CHIKVDF_VERSION_HPP

#include <cstdio>

#ifndef CHIKVDF_VERSION
#define CHIKVDF_VERSION "dev"
#endif

static inline void PrintCliVersion(const char *prog)
{
    if (!prog || !prog[0]) {
        prog = "chikvdf";
    }
    std::fprintf(stdout, "%s %s\n", prog, CHIKVDF_VERSION);
}

#endif
