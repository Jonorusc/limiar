#ifndef LIMIAR_SMC_H
#define LIMIAR_SMC_H

#include <stdint.h>

/// Opaque handle to an open AppleSMC user client (an io_connect_t).
typedef uint32_t smc_conn_t;

typedef struct {
    uint32_t data_size;
    uint32_t data_type;   // four-char code, big-endian packed
    uint8_t  attributes;
} smc_key_info_t;

/// Status codes returned by every function (0 = success).
enum {
    SMC_OK            = 0,
    SMC_ERR_OPEN      = -1,
    SMC_ERR_CALL      = -2,   // IOConnectCallStructMethod failed (e.g. not privileged)
    SMC_ERR_RESULT    = -3,   // SMC answered with a non-zero result byte
    SMC_ERR_SIZE      = -4,
};

int  smc_open(smc_conn_t *out_conn);
void smc_close(smc_conn_t conn);

/// `key` must point to exactly 4 ASCII characters (no terminator needed).
int smc_key_info(smc_conn_t conn, const char *key, smc_key_info_t *out_info);
/// Reads up to 32 bytes. `*inout_size` receives the key's data size.
int smc_read(smc_conn_t conn, const char *key, uint8_t *buf32, uint32_t *out_size);
/// Writes `size` bytes (<= 32). Requires root for protected keys.
int smc_write(smc_conn_t conn, const char *key, const uint8_t *buf, uint32_t size);

/// Last kern_return_t observed by a failing call (for diagnostics).
int smc_last_kern_return(void);

#endif
