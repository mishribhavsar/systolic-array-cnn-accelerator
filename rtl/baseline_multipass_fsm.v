`timescale 1ns / 1ps

module baseline_multipass_fsm #(
    parameter ARRAY_SIZE = 8,
    parameter ADDR_WIDTH = 8
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // Start/done
    input  wire                    start,
    output reg                     done,
    output reg                     busy,

    // Matrix dimensions (from config_regs)
    input  wire [15:0]             matrix_m_size,
    input  wire [15:0]             matrix_k_size,
    input  wire [15:0]             matrix_n_size,

    // Weight loading control (same as NMU FSM)
    output reg                     weight_load_en,
    output reg  [ADDR_WIDTH-1:0]   weight_load_addr,
    output reg                     weight_load_done,

    // Activation feeding control (same as NMU FSM)
    output reg                     act_feed_en,
    output reg  [ADDR_WIDTH-1:0]   act_feed_addr,

    // Array control
    output reg                     compute_enable,
    output reg                     acc_clear,

    // Output drain control
    output reg                     drain_enable,
    output reg                     drain_done,

    // NMU buffer control
    output reg                     buffer_swap,

    // Post-processing pass control (NEW — baseline specific)
    output reg                     pass_read_en,        // read from intermediate SRAM
    output reg  [ADDR_WIDTH-1:0]   pass_read_addr,      // read address for current pass row
    output reg                     pass_write_en,       // write to intermediate SRAM
    output reg  [ADDR_WIDTH-1:0]   pass_write_addr,     // write address for current pass row
    output reg  [ADDR_WIDTH-1:0]   pass_addr,           // address for current pass row (legacy alias)
    output reg  [2:0]              active_pass,         // which post-proc stage is active
                                                        // 0=none, 1=bias, 2=act, 3=quant, 4=pool

    // Tile tracking
    output reg  [15:0]             current_tile_m,
    output reg  [15:0]             current_tile_n,
    output reg  [15:0]             current_tile_k,

    // Performance counter events
    output wire                    perf_sram_rd_event,
    output wire                    perf_sram_wr_event,
    output wire                    perf_compute_active
);

  
    localparam S_IDLE         = 4'd0;
    localparam S_LOAD_WEIGHTS = 4'd1;
    localparam S_LOAD_BIAS    = 4'd2;
    localparam S_LOAD_ACT     = 4'd3;
    localparam S_COMPUTE      = 4'd4;
    localparam S_DRAIN        = 4'd5;
    localparam S_BIAS_PASS    = 4'd6;
    localparam S_ACT_PASS     = 4'd7;
    localparam S_QUANT_PASS   = 4'd8;
    localparam S_POOL_PASS    = 4'd9;
    localparam S_DONE         = 4'd10;

    reg [3:0] state, next_state;
    reg [15:0] cycle_cnt;

    // Pipeline latency for each pass: 1 cycle read + 1 cycle process + 1 cycle write = 3 cycles per row
    // But since we pipeline it, effective is ARRAY_SIZE + 2 cycles per pass
    localparam PASS_CYCLES = ARRAY_SIZE + 2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:         if (start)                                   next_state = S_LOAD_WEIGHTS;
            S_LOAD_WEIGHTS: if (cycle_cnt == ARRAY_SIZE - 1)             next_state = S_LOAD_BIAS;
            S_LOAD_BIAS:    if (cycle_cnt == ARRAY_SIZE - 1)             next_state = S_LOAD_ACT;
            S_LOAD_ACT:     if (cycle_cnt == (2 * ARRAY_SIZE - 2))       next_state = S_COMPUTE;
            S_COMPUTE:      if (cycle_cnt == ARRAY_SIZE - 1)             next_state = S_DRAIN;
            S_DRAIN:        if (cycle_cnt == (2 * ARRAY_SIZE - 2))       next_state = S_BIAS_PASS;
            S_BIAS_PASS:    if (cycle_cnt == PASS_CYCLES - 1)            next_state = S_ACT_PASS;
            S_ACT_PASS:     if (cycle_cnt == PASS_CYCLES - 1)            next_state = S_QUANT_PASS;
            S_QUANT_PASS:   if (cycle_cnt == PASS_CYCLES - 1)            next_state = S_POOL_PASS;
            S_POOL_PASS:    if (cycle_cnt == PASS_CYCLES - 1)            next_state = S_DONE;
            S_DONE:                                                      next_state = S_IDLE;
            default:                                                     next_state = S_IDLE;
        endcase
    end

   
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_cnt        <= 0;
            done             <= 0;
            busy             <= 0;
            weight_load_en   <= 0;
            weight_load_addr <= 0;
            weight_load_done <= 0;
            act_feed_en      <= 0;
            act_feed_addr    <= 0;
            compute_enable   <= 0;
            acc_clear        <= 0;
            drain_enable     <= 0;
            drain_done       <= 0;
            buffer_swap      <= 0;
            pass_read_en     <= 0;
            pass_read_addr   <= 0;
            pass_write_en    <= 0;
            pass_write_addr  <= 0;
            pass_addr        <= 0;
            active_pass      <= 0;
            current_tile_m   <= 0;
            current_tile_n   <= 0;
            current_tile_k   <= 0;
        end else begin
            // Defaults (self-clearing signals)
            weight_load_en   <= 0;
            weight_load_done <= 0;
            act_feed_en      <= 0;
            compute_enable   <= 0;
            acc_clear        <= 0;
            drain_enable     <= 0;
            drain_done       <= 0;
            buffer_swap      <= 0;
            pass_read_en     <= 0;
            pass_read_addr   <= 0;
            pass_write_en    <= 0;
            pass_write_addr  <= 0;
            pass_addr        <= 0;
            done             <= 0;

            case (state)
                // ---------------------------------------------------------
                S_IDLE: begin
                    busy <= 0;
                    cycle_cnt <= 0;
                    active_pass <= 0;
                    if (start) begin
                        busy <= 1;
                        current_tile_m <= 0;
                        current_tile_n <= 0;
                        current_tile_k <= 0;
                        weight_load_addr <= ARRAY_SIZE - 1;
                    end
                end

                S_LOAD_WEIGHTS: begin
                    weight_load_en <= 1;
                    if (cycle_cnt < ARRAY_SIZE - 1) begin
                        weight_load_addr <= weight_load_addr - 1;
                        cycle_cnt <= cycle_cnt + 1;
                    end else begin
                        weight_load_done <= 1;
                        cycle_cnt <= 0;
                    end
                end

                S_LOAD_BIAS: begin
                    if (cycle_cnt < ARRAY_SIZE - 1) begin
                        cycle_cnt <= cycle_cnt + 1;
                    end else begin
                        cycle_cnt <= 0;
                        act_feed_addr <= 0;
                    end
                end

                S_LOAD_ACT: begin
                    act_feed_en    <= 1;
                    compute_enable <= 1;
                    if (cycle_cnt == 0)
                        acc_clear <= 1;
                    // Start drain when first output row emerges
                    if (cycle_cnt >= ARRAY_SIZE)
                        drain_enable <= 1;
                    if (cycle_cnt < (2 * ARRAY_SIZE - 2)) begin
                        act_feed_addr <= act_feed_addr + 1;
                        cycle_cnt <= cycle_cnt + 1;
                    end else begin
                        cycle_cnt <= 0;
                    end
                end

                S_COMPUTE: begin
                    compute_enable <= 1;
                    drain_enable   <= 1;
                    if (cycle_cnt < ARRAY_SIZE - 1)
                        cycle_cnt <= cycle_cnt + 1;
                    else
                        cycle_cnt <= 0;
                end

                S_DRAIN: begin
                    drain_enable <= 1;
                    // Drain remaining results into intermediate SRAM
                    // (In baseline, raw psums go to inter SRAM, NOT through NMU pipeline)
                    if (cycle_cnt < (2 * ARRAY_SIZE - 2)) begin
                        cycle_cnt <= cycle_cnt + 1;
                    end else begin
                        drain_done <= 1;
                        cycle_cnt <= 0;
                    end
                end

           
                S_BIAS_PASS: begin
                    active_pass <= 3'd1;
                    if (cycle_cnt < ARRAY_SIZE) begin
                        pass_read_en   <= 1;
                        pass_read_addr <= cycle_cnt[ADDR_WIDTH-1:0];
                        pass_addr      <= cycle_cnt[ADDR_WIDTH-1:0];
                    end
                    // Write follows read by 2 cycles (1 SRAM read latency + 1 process latency)
                    if (cycle_cnt >= 2 && cycle_cnt < ARRAY_SIZE + 2) begin
                        pass_write_en   <= 1;
                        pass_write_addr <= cycle_cnt[ADDR_WIDTH-1:0] - 2'd2;
                    end
                    if (cycle_cnt < PASS_CYCLES - 1)
                        cycle_cnt <= cycle_cnt + 1;
                    else
                        cycle_cnt <= 0;
                end

                S_ACT_PASS: begin
                    active_pass <= 3'd2;
                    if (cycle_cnt < ARRAY_SIZE) begin
                        pass_read_en   <= 1;
                        pass_read_addr <= cycle_cnt[ADDR_WIDTH-1:0];
                        pass_addr      <= cycle_cnt[ADDR_WIDTH-1:0];
                    end
                    if (cycle_cnt >= 2 && cycle_cnt < ARRAY_SIZE + 2) begin
                        pass_write_en   <= 1;
                        pass_write_addr <= cycle_cnt[ADDR_WIDTH-1:0] - 2'd2;
                    end
                    if (cycle_cnt < PASS_CYCLES - 1)
                        cycle_cnt <= cycle_cnt + 1;
                    else
                        cycle_cnt <= 0;
                end

                S_QUANT_PASS: begin
                    active_pass <= 3'd3;
                    if (cycle_cnt < ARRAY_SIZE) begin
                        pass_read_en   <= 1;
                        pass_read_addr <= cycle_cnt[ADDR_WIDTH-1:0];
                        pass_addr      <= cycle_cnt[ADDR_WIDTH-1:0];
                    end
                    if (cycle_cnt >= 2 && cycle_cnt < ARRAY_SIZE + 2) begin
                        pass_write_en   <= 1;
                        pass_write_addr <= cycle_cnt[ADDR_WIDTH-1:0] - 2'd2;
                    end
                    if (cycle_cnt < PASS_CYCLES - 1)
                        cycle_cnt <= cycle_cnt + 1;
                    else
                        cycle_cnt <= 0;
                end

                S_POOL_PASS: begin
                    active_pass <= 3'd4;
                    if (cycle_cnt < ARRAY_SIZE) begin
                        pass_read_en   <= 1;
                        pass_read_addr <= cycle_cnt[ADDR_WIDTH-1:0];
                        pass_addr      <= cycle_cnt[ADDR_WIDTH-1:0];
                    end
                    if (cycle_cnt >= 2 && cycle_cnt < ARRAY_SIZE + 2) begin
                        pass_write_en   <= 1;
                        pass_write_addr <= cycle_cnt[ADDR_WIDTH-1:0] - 2'd2;
                    end
                    if (cycle_cnt < PASS_CYCLES - 1)
                        cycle_cnt <= cycle_cnt + 1;
                    else
                        cycle_cnt <= 0;
                end

                S_DONE: begin
                    done <= 1;
                    busy <= 0;
                    active_pass <= 0;
                end
            endcase
        end
    end

    
    assign perf_sram_rd_event  = pass_read_en;
    assign perf_sram_wr_event  = pass_write_en;
    assign perf_compute_active = compute_enable;

endmodule
