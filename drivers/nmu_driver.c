

#include "nmu_driver.h"
#include <stdio.h>

#define REG_WRITE(addr, val)   (*(volatile uint32_t *)(addr) = (uint32_t)(val))
#define REG_READ(addr)        (*(volatile uint32_t *)(addr))

void nmu_init(const nmu_config_t *cfg) {
    if (!cfg || cfg->base_address == 0) return;

    uint32_t base = cfg->base_address;

    REG_WRITE(base + NMU_REG_MATRIX_M,    cfg->m);
    REG_WRITE(base + NMU_REG_MATRIX_K,    cfg->k);
    REG_WRITE(base + NMU_REG_MATRIX_N,    cfg->n);
    REG_WRITE(base + NMU_REG_ACT_MODE,    cfg->act_mode);
    REG_WRITE(base + NMU_REG_POOL_EN,     cfg->pool_enable ? 1 : 0);
    REG_WRITE(base + NMU_REG_QUANT_SHIFT, cfg->quant_shift);
    REG_WRITE(base + NMU_REG_LEAKY_SHIFT, cfg->leaky_shift);
    REG_WRITE(base + NMU_REG_BIAS_BASE,   cfg->bias_base);
}

void nmu_start(uint32_t base_addr) {
    REG_WRITE(base_addr + NMU_REG_START, 0x00000001);
}

bool nmu_wait_done(uint32_t base_addr, uint32_t timeout_cycles) {
    uint32_t count = 0;
    while (count < timeout_cycles) {
        uint32_t status = REG_READ(base_addr + NMU_REG_STATUS);
        if (status & NMU_STATUS_DONE_MASK) {
            return true;
        }
        count++;
    }
    return false; // Timed out
}

void nmu_read_telemetry(uint32_t base_addr, nmu_telemetry_t *telem) {
    if (!telem) return;

    telem->total_cycles             = REG_READ(base_addr + NMU_REG_PERF_TOTAL);
    telem->intermediate_sram_reads  = REG_READ(base_addr + NMU_REG_PERF_SRAM_RD);
    telem->intermediate_sram_writes = REG_READ(base_addr + NMU_REG_PERF_SRAM_WR);
    telem->active_compute_cycles    = REG_READ(base_addr + NMU_REG_PERF_COMPUTE);
    telem->stall_cycles             = REG_READ(base_addr + NMU_REG_PERF_STALL);
    telem->zero_activations_skipped = REG_READ(base_addr + NMU_REG_PERF_ZERO_SKIP);
    telem->output_elements          = REG_READ(base_addr + NMU_REG_OUTPUT_COUNT);
}

void nmu_print_telemetry(const nmu_telemetry_t *telem, bool is_nmu) {
    if (!telem) return;

    printf("  %s Performance Telemetry Report\n", is_nmu ? "NMU Fused Architecture" : "Baseline Architecture");
    printf("  Total Execution Cycles       : %10u cycles\n", telem->total_cycles);
    printf("  Active Compute Cycles        : %10u cycles\n", telem->active_compute_cycles);
    printf("  Pipeline Stall Cycles        : %10u cycles\n", telem->stall_cycles);
    printf("  Intermediate SRAM Reads      : %10u accesses\n", telem->intermediate_sram_reads);
    printf("  Intermediate SRAM Writes     : %10u accesses\n", telem->intermediate_sram_writes);
    printf("  Zero Activations Skipped     : %10u ops\n", telem->zero_activations_skipped);
    printf("  Total Output Elements        : %10u words\n", telem->output_elements);
    if (is_nmu) {
        printf("  [NMU BENEFIT] Intermediate SRAM Traffic = ZERO (100%% eliminated!)\n");
    } else {
        printf("  [BASELINE OVERHEAD] Intermediate SRAM Traffic = %u accesses\n",
               telem->intermediate_sram_reads + telem->intermediate_sram_writes);
    }
}
