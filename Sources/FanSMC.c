// Minimal AppleSMC transport for fan telemetry and fan target control.
//
// The fan keys and mode sequence are the common AppleSMC interface also used by
// FanBar (GPL-3.0) and other fan utilities. This is an independent implementation
// written for VibeDeck; no FanBar source code is copied here.
//
// macOS does not publish an API for the SMC fan keys, but the external-method
// ABI below is the long-standing interface used by fan utilities. Reads work as
// the logged-in user; writes to F0Md / F0Tg need root, so the app runs its
// --fan-set / --fan-auto entry points through the system authorization prompt.

#include "FanSMC.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} VGSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuLimit;
    uint32_t gpuLimit;
    uint32_t memoryLimit;
} VGSMCLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} VGSMCKeyInfo;

typedef struct {
    uint32_t key;
    VGSMCVersion version;
    uint16_t limitDataSize;
    VGSMCLimitData limitData;
    VGSMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} VGSMCParam;

enum {
    VG_SMC_GET_KEY_INFO = 9,
    VG_SMC_READ_BYTES = 5,
    VG_SMC_WRITE_BYTES = 6,
    VG_SMC_GET_KEY_FROM_INDEX = 8,
    VG_SMC_METHOD = 2,
};

static io_connect_t vg_connection = IO_OBJECT_NULL;

static kern_return_t vg_call(VGSMCParam *input, VGSMCParam *output) {
    size_t size = sizeof(*output);
    return IOConnectCallStructMethod(vg_connection, VG_SMC_METHOD, input, sizeof(*input), output, &size);
}

int vg_smc_open(void) {
    if (vg_connection != IO_OBJECT_NULL) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return KERN_FAILURE;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &vg_connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) vg_connection = IO_OBJECT_NULL;
    return (int)result;
}

void vg_smc_close(void) {
    if (vg_connection != IO_OBJECT_NULL) {
        IOServiceClose(vg_connection);
        vg_connection = IO_OBJECT_NULL;
    }
}

int vg_smc_read(uint32_t key, uint32_t *type, uint32_t *size, uint8_t *bytes) {
    if (vg_connection == IO_OBJECT_NULL) return KERN_INVALID_ARGUMENT;
    VGSMCParam input;
    VGSMCParam output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key;
    input.data8 = VG_SMC_GET_KEY_INFO;
    kern_return_t result = vg_call(&input, &output);
    if (result != KERN_SUCCESS) return (int)result;
    if (output.result != 0) return 0x10000 | output.result;

    VGSMCKeyInfo info = output.keyInfo;
    input.keyInfo = info;
    input.data8 = VG_SMC_READ_BYTES;
    memset(&output, 0, sizeof(output));
    result = vg_call(&input, &output);
    if (result != KERN_SUCCESS) return (int)result;
    if (output.result != 0) return 0x10000 | output.result;

    if (type != NULL) *type = info.dataType;
    if (size != NULL) *size = info.dataSize;
    if (bytes != NULL) memcpy(bytes, output.bytes, sizeof(output.bytes));
    return 0;
}

int vg_smc_write(uint32_t key, uint32_t type, uint32_t size, const uint8_t *bytes) {
    if (vg_connection == IO_OBJECT_NULL || bytes == NULL || size > 32) return KERN_INVALID_ARGUMENT;
    VGSMCParam input;
    VGSMCParam output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key;
    input.keyInfo.dataType = type;
    input.keyInfo.dataSize = size;
    input.data8 = VG_SMC_WRITE_BYTES;
    memcpy(input.bytes, bytes, size);
    kern_return_t result = vg_call(&input, &output);
    if (result != KERN_SUCCESS) return (int)result;
    if (output.result != 0) return 0x10000 | output.result;
    return 0;
}

int vg_smc_key_at(uint32_t index, uint32_t *key) {
    if (vg_connection == IO_OBJECT_NULL || key == NULL) return KERN_INVALID_ARGUMENT;
    VGSMCParam input;
    VGSMCParam output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.data8 = VG_SMC_GET_KEY_FROM_INDEX;
    input.data32 = index;
    kern_return_t result = vg_call(&input, &output);
    if (result != KERN_SUCCESS) return (int)result;
    if (output.result != 0) return 0x10000 | output.result;
    *key = output.key;
    return 0;
}
