#ifndef CHIKVDF_PROFILE_H
#define CHIKVDF_PROFILE_H

#include <cstdint>

// This header centralizes optional profiling hooks used by `vdf.h` (driver) and
// hot-loop primitives like NUDUPL (`nucomp.h`). Everything is no-op unless:
// - `VDF_TEST` is enabled (VDF_MODE=1), and
// - the caller sets `chikvdf_nudupl_profile_sink` (and optionally enables timing).

struct chikvdf_nudupl_profile_stats {
    // Outer-loop counts (from `repeated_square_nudupl`).
    uint64_t iters = 0;
    uint64_t reduce_calls = 0;
    uint64_t reduce_skipped = 0;
    uint64_t max_a_limbs = 0;

    // Outer-loop timing (from `repeated_square_nudupl`).
    uint64_t nudupl_form_time_ns = 0;
    uint64_t reduce_time_ns = 0;

    // Inner-loop breakdown (from `qfb_nudupl`).
    uint64_t qfb_nudupl_calls = 0;
    uint64_t b_negative = 0;
    uint64_t branch_a_lt_L = 0;
    uint64_t branch_a_ge_L = 0;

    uint64_t gcdext_time_ns = 0;
    uint64_t gcdext_s_eq_1 = 0;
    uint64_t gcdext_s_ne_1 = 0;
    uint64_t xgcd_partial_time_ns = 0;
    uint64_t else_branch_time_ns = 0; // time spent in the a>=L branch overall
};

#if defined(VDF_TEST)
inline thread_local chikvdf_nudupl_profile_stats* chikvdf_nudupl_profile_sink = nullptr;
inline thread_local bool chikvdf_nudupl_profile_timing_enabled = false;
#endif

#endif // CHIKVDF_PROFILE_H
