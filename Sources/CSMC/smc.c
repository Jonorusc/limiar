#include "smc.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

// Layout expected by the AppleSMC user client (selector 2, struct in/out).
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

enum { kSMCUserClientSelector = 2, kCmdReadBytes = 5, kCmdWriteBytes = 6, kCmdReadKeyInfo = 9 };

static _Thread_local int last_kr = 0;

int smc_last_kern_return(void) { return last_kr; }

static uint32_t fourcc(const char *k) {
    return ((uint32_t)(uint8_t)k[0] << 24) | ((uint32_t)(uint8_t)k[1] << 16) |
           ((uint32_t)(uint8_t)k[2] << 8)  |  (uint32_t)(uint8_t)k[3];
}

static int call(smc_conn_t conn, SMCKeyData *in, SMCKeyData *out) {
    size_t size = sizeof(SMCKeyData);
    kern_return_t kr = IOConnectCallStructMethod((io_connect_t)conn, kSMCUserClientSelector,
                                                 in, sizeof(SMCKeyData), out, &size);
    last_kr = kr;
    if (kr != KERN_SUCCESS) return SMC_ERR_CALL;
    if (out->result != 0) return SMC_ERR_RESULT;
    return SMC_OK;
}

int smc_open(smc_conn_t *out_conn) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return SMC_ERR_OPEN;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    last_kr = kr;
    if (kr != KERN_SUCCESS) return SMC_ERR_OPEN;
    *out_conn = (smc_conn_t)conn;
    return SMC_OK;
}

void smc_close(smc_conn_t conn) {
    if (conn) IOServiceClose((io_connect_t)conn);
}

int smc_key_info(smc_conn_t conn, const char *key, smc_key_info_t *out_info) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.data8 = kCmdReadKeyInfo;
    int rc = call(conn, &in, &out);
    if (rc != SMC_OK) return rc;
    out_info->data_size = out.keyInfo.dataSize;
    out_info->data_type = out.keyInfo.dataType;
    out_info->attributes = out.keyInfo.dataAttributes;
    return SMC_OK;
}

int smc_read(smc_conn_t conn, const char *key, uint8_t *buf32, uint32_t *out_size) {
    smc_key_info_t info;
    int rc = smc_key_info(conn, key, &info);
    if (rc != SMC_OK) return rc;
    if (info.data_size > 32) return SMC_ERR_SIZE;

    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.data_size;
    in.data8 = kCmdReadBytes;
    rc = call(conn, &in, &out);
    if (rc != SMC_OK) return rc;
    memcpy(buf32, out.bytes, 32);
    *out_size = info.data_size;
    return SMC_OK;
}

int smc_write(smc_conn_t conn, const char *key, const uint8_t *buf, uint32_t size) {
    if (size == 0 || size > 32) return SMC_ERR_SIZE;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.keyInfo.dataSize = size;
    in.data8 = kCmdWriteBytes;
    memcpy(in.bytes, buf, size);
    return call(conn, &in, &out);
}
