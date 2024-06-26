#ifndef CHIK_DRIVER_HPP
#define CHIK_DRIVER_HPP

#include <gmp.h>

#include "vdf_driver.hpp"
#include "chik_registers.hpp"

class ChikDriver : public VdfDriver {
public:
  const static unsigned NUM_1X_COEFFS = 18;
  const static unsigned NUM_2X_COEFFS = 34;
  const static unsigned NUM_3X_COEFFS = 52;
  const static unsigned NUM_4X_COEFFS = 68;

  ChikDriver() :
    VdfDriver(16 /*WORD_BITS*/, 19 /*REDUNDANT_BITS*/, true) {
  }

  virtual size_t CmdSize() {
    return (CHIK_VDF_CMD_START_REG_OFFSET -
            CHIK_VDF_CMD_JOB_ID_REG_OFFSET + REG_BYTES);
  }

  virtual size_t StatusSize() {
    return (CHIK_VDF_STATUS_END_REG_OFFSET -
            CHIK_VDF_STATUS_ITER_0_REG_OFFSET);
  }

  void SerializeJob(uint8_t *buf,
                    uint32_t job_id,
                    uint64_t iteration_count,
                    mpz_t a,
                    mpz_t f,
                    mpz_t d,
                    mpz_t l);

  void DeserializeJob(uint8_t *buf,
                      uint32_t &job_id,
                      uint64_t &iteration_count,
                      mpz_t a,
                      mpz_t f);
};
#endif
