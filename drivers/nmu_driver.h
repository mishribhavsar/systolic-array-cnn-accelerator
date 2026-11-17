
#ifndef NMU_DRIVER_H
#define NMU_DRIVER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Register Offset Definitions (AXI4-Lite Slave Interface)

#define NMU_REG_START           0x00    // (W) Write 1 to trigger execution
#define NMU_REG_MATRIX_M        0x04    // (W) Matrix M dimension (rows)
#define NMU_REG_MATRIX_K        0x08    // (W) Matrix K dimension (inner)
#define NMU_REG_MATRIX_N        0x0C    // (W) Matrix N dimension (cols)
#define NMU_REG_ACT_MODE        0x10    // (W) 0=Bypass, 1=ReLU, 2=LeakyReLU
#define NMU_REG_POOL_EN         0x14    // (W) 0=Disable, 1=Enable 2x2 MaxPool
#define NMU_REG_QUANT_SHIFT     0x18    // (W) Right-shift amount for 32->16 bit quant
#define NMU_REG_LEAKY_SHIFT     0x1C    // (W) Right-shift for negative LeakyReLU slope
#define NMU_REG_BIAS_BASE       0x20    // (W) Base address in Bias SRAM
#define NMU_REG_STATUS          0x24    // (R) Status: bit2=output_valid, bit1=busy, bit0=done
#define NMU_REG_OUTPUT_COUNT    0x28    // (R) Total output elements generated
#define NMU_REG_PERF_TOTAL      0x2C    // (R) Total elapsed clock cycles
#define NMU_REG_PERF_SRAM_RD    0x30    // (R) Intermediate SRAM read operations
#define NMU_REG_PERF_SRAM_WR    0x34    // (R) Intermediate SRAM write operations
#define NMU_REG_PERF_COMPUTE    0x38    // (R) Active compute cycles
#define NMU_REG_PERF_STALL      0x3C    // (R) Pipeline stall cycles
#define NMU_REG_PERF_ZERO_SKIP  0x40    // (R) Zero activations skipped (power savings)

// Activation mode constants 
#define NMU_ACT_BYPASS          0       // Mode 0: pass-through (no activation)
#define NMU_ACT_RELU            1       // Mode 1: ReLU (clamp negatives to 0)
#define NMU_ACT_LEAKY_RELU      2       // Mode 2: Leaky ReLU (negative *= 2^-shift)

// Status bitmasks
#define NMU_STATUS_DONE_MASK    (1U << 0)
#define NMU_STATUS_BUSY_MASK    (1U << 1)
#define NMU_STATUS_VALID_MASK   (1U << 2)


// Configuration Struct
typedef struct {
    uint32_t base_address;      // AXI-Lite memory-mapped base address
    uint16_t m;                 // M dimension
    uint16_t k;                 // K dimension
    uint16_t n;                 // N dimension
    uint8_t  act_mode;          // Activation mode
    bool     pool_enable;       // Pooling enable
    uint8_t  quant_shift;       // Quantization shift
    uint8_t  leaky_shift;       // LeakyReLU negative shift
    uint8_t  bias_base;         // Bias SRAM base address
} nmu_config_t;


// Telemetry Struct

typedef struct {
    uint32_t total_cycles;
    uint32_t intermediate_sram_reads;
    uint32_t intermediate_sram_writes;
    uint32_t active_compute_cycles;
    uint32_t stall_cycles;
    uint32_t zero_activations_skipped;
    uint32_t output_elements;
} nmu_telemetry_t;


void nmu_init(const nmu_config_t *cfg);


void nmu_start(uint32_t base_addr);

bool nmu_wait_done(uint32_t base_addr, uint32_t timeout_cycles);


void nmu_read_telemetry(uint32_t base_addr, nmu_telemetry_t *telem);


void nmu_print_telemetry(const nmu_telemetry_t *telem, bool is_nmu);

#ifdef __cplusplus
}
#endif

#endif // NMU_DRIVER_H
