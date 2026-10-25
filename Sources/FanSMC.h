#ifndef VIBEGAUGE_FAN_SMC_H
#define VIBEGAUGE_FAN_SMC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opens one process-wide connection to AppleSMC. Returns 0 or a kern_return_t.
int vg_smc_open(void);
void vg_smc_close(void);

/// Reads one four-character SMC key. Returns 0, a kern_return_t, or
/// 0x10000 | smc_result for key-level failures.
int vg_smc_read(uint32_t key, uint32_t *type, uint32_t *size, uint8_t *bytes);

/// Writes one SMC key. Fan writes need root; reads do not.
int vg_smc_write(uint32_t key, uint32_t type, uint32_t size, const uint8_t *bytes);

/// Reads the key name at an enumeration index (0 ..< #KEY). Read-only.
int vg_smc_key_at(uint32_t index, uint32_t *key);

#ifdef __cplusplus
}
#endif

#endif
