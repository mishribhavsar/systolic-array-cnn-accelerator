`timescale 1ns / 1ps

module performance_counters (
    input  wire        clk,
    input  wire        rst_n,

    // Control
    input  wire        clear,              // pulse to reset all counters (tie to start)
    input  wire        counting_enable,    // gate all counting (tie to busy)

    // Event inputs (active-high pulses or levels)
    input  wire        sram_read_event,    // pulse: one SRAM read occurred this cycle
    input  wire        sram_write_event,   // pulse: one SRAM write occurred this cycle
    input  wire        compute_active,     // level: PEs are computing this cycle
    input  wire        stall_event,        // pulse: pipeline stall this cycle
    input  wire        zero_skip_event,    // pulse: zero-skip occurred this cycle

    // Counter outputs (directly readable via config register map)
    output wire [31:0] total_cycles,
    output wire [31:0] sram_read_count,
    output wire [31:0] sram_write_count,
    output wire [31:0] compute_active_cycles,
    output wire [31:0] stall_cycles,
    output wire [31:0] zero_skip_count
);

    // Internal counter registers
    reg [31:0] cnt_total;
    reg [31:0] cnt_sram_rd;
    reg [31:0] cnt_sram_wr;
    reg [31:0] cnt_compute;
    reg [31:0] cnt_stall;
    reg [31:0] cnt_zero_skip;

    // Saturating increment function
    // Returns current + 1, clamped at 32'hFFFFFFFF
    function [31:0] sat_inc;
        input [31:0] val;
        begin
            sat_inc = (val == 32'hFFFF_FFFF) ? val : val + 32'd1;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_total     <= 32'd0;
            cnt_sram_rd   <= 32'd0;
            cnt_sram_wr   <= 32'd0;
            cnt_compute   <= 32'd0;
            cnt_stall     <= 32'd0;
            cnt_zero_skip <= 32'd0;
        end else if (clear) begin
            cnt_total     <= 32'd0;
            cnt_sram_rd   <= 32'd0;
            cnt_sram_wr   <= 32'd0;
            cnt_compute   <= 32'd0;
            cnt_stall     <= 32'd0;
            cnt_zero_skip <= 32'd0;
        end else if (counting_enable) begin
            // Counter 0: Total cycles (always increments while enabled)
            cnt_total <= sat_inc(cnt_total);

            // Counter 1: SRAM reads
            if (sram_read_event)
                cnt_sram_rd <= sat_inc(cnt_sram_rd);

            // Counter 2: SRAM writes
            if (sram_write_event)
                cnt_sram_wr <= sat_inc(cnt_sram_wr);

            // Counter 3: Compute-active cycles
            if (compute_active)
                cnt_compute <= sat_inc(cnt_compute);

            // Counter 4: Stall cycles
            if (stall_event)
                cnt_stall <= sat_inc(cnt_stall);

            // Counter 5: Zero-skip count
            if (zero_skip_event)
                cnt_zero_skip <= sat_inc(cnt_zero_skip);
        end
    end

    // Output assignments
    assign total_cycles          = cnt_total;
    assign sram_read_count       = cnt_sram_rd;
    assign sram_write_count      = cnt_sram_wr;
    assign compute_active_cycles = cnt_compute;
    assign stall_cycles          = cnt_stall;
    assign zero_skip_count       = cnt_zero_skip;

endmodule
