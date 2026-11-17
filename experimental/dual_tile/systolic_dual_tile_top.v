`timescale 1ns / 1ps

module systolic_dual_tile_top #(
    parameter TILE_SIZE      = 4,
    parameter DATA_WIDTH     = 8,
    parameter ACC_WIDTH      = 32,
    parameter OUTPUT_WIDTH   = 16,
    parameter SRAM_DEPTH     = 256,
    parameter ADDR_WIDTH     = 8,
    parameter CFG_ADDR_WIDTH = 4
)(
    input  wire                                     clk,
    input  wire                                     rst_n,

    // Configuration Interface
    input  wire                                     cfg_we,
    input  wire [CFG_ADDR_WIDTH-1:0]                cfg_addr,
    input  wire [31:0]                              cfg_wdata,
    input  wire [CFG_ADDR_WIDTH-1:0]                cfg_raddr,
    output wire [31:0]                              cfg_rdata,

    // External Memory Write Interface (bit [ADDR_WIDTH] or dedicated select)
    input  wire                                     ext_tile_sel, // 0 = Tile 0, 1 = Tile 1
    input  wire [ADDR_WIDTH-1:0]                    ext_waddr,
    input  wire [TILE_SIZE*DATA_WIDTH-1:0]          ext_wdata,
    input  wire                                     ext_weight_we,
    input  wire                                     ext_act_we,

    // Bias Interface (shared bias BRAM)
    input  wire [ADDR_WIDTH-1:0]                    bias_waddr,
    input  wire signed [TILE_SIZE*ACC_WIDTH-1:0]    bias_wdata,
    input  wire                                     bias_we,

    // Output Read Interface (reads from shared NMU output SRAM)
    input  wire [ADDR_WIDTH-1:0]                    out_raddr,
    output wire [TILE_SIZE*OUTPUT_WIDTH-1:0]        out_rdata,

    // System Status
    output wire                                     busy,
    output wire                                     done,
    output wire                                     output_valid,
    output wire [ADDR_WIDTH-1:0]                    output_count,

    // Telemetry
    output wire [31:0]                              perf_total_cycles,
    output wire [31:0]                              perf_active_cycles,
    output wire [31:0]                              perf_tile0_computes,
    output wire [31:0]                              perf_tile1_computes
);

    wire [15:0] matrix_m_size;
    wire [15:0] matrix_k_size;
    wire [15:0] matrix_n_size;
    wire [1:0]  activation_mode;
    wire        pooling_enable;
    wire [3:0]  quantize_shift;
    wire [3:0]  leaky_shift;
    wire [ADDR_WIDTH-1:0] bias_base_addr;
    wire        start_pulse;

    config_regs #(.ADDR_WIDTH(CFG_ADDR_WIDTH)) u_config_regs (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_raddr(cfg_raddr), .cfg_rdata(cfg_rdata),
        .matrix_m_size(matrix_m_size), .matrix_k_size(matrix_k_size),
        .matrix_n_size(matrix_n_size),
        .activation_mode(activation_mode), .pooling_enable(pooling_enable),
        .quantize_shift(quantize_shift), .leaky_shift(leaky_shift),
        .bias_base_addr(bias_base_addr), .start_pulse(start_pulse),
        .perf_total_cycles(perf_total_cycles),
        .perf_sram_read_count(32'd0),
        .perf_sram_write_count(32'd0),
        .perf_compute_active_cycles(perf_active_cycles),
        .perf_stall_cycles(32'd0),
        .perf_zero_skip_count(32'd0)
    );


    wire signed [TILE_SIZE*ACC_WIDTH-1:0] bias_flat;
    sram_bank #(
        .DATA_WIDTH(TILE_SIZE*ACC_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .SRAM_DEPTH(SRAM_DEPTH)
    ) u_shared_bias_sram (
        .clk  (clk),
        .we   (bias_we),
        .waddr(bias_waddr),
        .wdata(bias_wdata),
        .raddr(bias_base_addr[ADDR_WIDTH-1:0]),
        .rdata(bias_flat)
    );

    wire [1:0]                               tile_result_valid;
    wire [2*TILE_SIZE*ACC_WIDTH-1:0]         tile_result_flat;
    wire [1:0]                               tile_grant;
    wire [1:0]                               tile_busy;
    wire [1:0]                               tile_done;

    genvar t;
    generate
        for (t = 0; t < 2; t = t + 1) begin : gen_tiles
            // Tile control signals
            wire fsm_weight_load_en;
            wire [ADDR_WIDTH-1:0] fsm_weight_load_addr;
            wire fsm_weight_load_done;
            wire fsm_act_feed_en;
            wire [ADDR_WIDTH-1:0] fsm_act_feed_addr;
            wire fsm_compute_enable;
            wire fsm_acc_clear;
            wire fsm_drain_enable;
            wire fsm_drain_done;
            wire fsm_buffer_swap;
            wire fsm_post_proc_enable;
            wire fsm_post_proc_valid;

            // FSM instance per tile
            controller_fsm #(
                .ARRAY_SIZE(TILE_SIZE), .ADDR_WIDTH(ADDR_WIDTH)
            ) u_fsm (
                .clk(clk), .rst_n(rst_n),
                .start(start_pulse),
                .done(tile_done[t]),
                .busy(tile_busy[t]),
                .matrix_m_size(matrix_m_size),
                .matrix_k_size(matrix_k_size),
                .matrix_n_size(matrix_n_size),
                .weight_load_en(fsm_weight_load_en),
                .weight_load_addr(fsm_weight_load_addr),
                .weight_load_done(fsm_weight_load_done),
                .act_feed_en(fsm_act_feed_en),
                .act_feed_addr(fsm_act_feed_addr),
                .compute_enable(fsm_compute_enable),
                .acc_clear(fsm_acc_clear),
                .drain_enable(fsm_drain_enable),
                .drain_done(fsm_drain_done),
                .buffer_swap(fsm_buffer_swap),
                .post_proc_enable(fsm_post_proc_enable),
                .post_proc_valid(fsm_post_proc_valid),
                .current_tile_m(), .current_tile_n(), .current_tile_k()
            );

            // Input memory per tile
            wire [TILE_SIZE*DATA_WIDTH-1:0] tile_weight_out;
            wire [TILE_SIZE*DATA_WIDTH-1:0] tile_act_out;
            wire [TILE_SIZE-1:0]            tile_act_zero_flags;

            wire tile_ext_weight_we = ext_weight_we && (ext_tile_sel == t);
            wire tile_ext_act_we    = ext_act_we    && (ext_tile_sel == t);

            near_memory_input #(
                .ARRAY_SIZE(TILE_SIZE), .DATA_WIDTH(DATA_WIDTH),
                .SRAM_DEPTH(SRAM_DEPTH), .ADDR_WIDTH(ADDR_WIDTH)
            ) u_mem_in (
                .clk(clk), .rst_n(rst_n),
                .load_weights(fsm_weight_load_en),
                .load_activations(fsm_act_feed_en),
                .compute_start(fsm_compute_enable),
                .buffer_swap(fsm_buffer_swap),
                .ext_waddr(ext_waddr),
                .ext_wdata(ext_wdata),
                .ext_weight_we(tile_ext_weight_we),
                .ext_act_we(tile_ext_act_we),
                .weight_out_flat(tile_weight_out),
                .weight_raddr(fsm_weight_load_addr),
                .act_out_flat(tile_act_out),
                .act_raddr(fsm_act_feed_addr),
                .act_zero_flags(tile_act_zero_flags)
            );

            // Skew registers for activations
            wire [TILE_SIZE*DATA_WIDTH-1:0] skewed_act;
            genvar r, sk;
            for (r = 0; r < TILE_SIZE; r = r + 1) begin : gen_row_skew
                wire signed [DATA_WIDTH-1:0] act_element = tile_act_out[(r*DATA_WIDTH) +: DATA_WIDTH];
                if (r == 0) begin : r0
                    reg signed [DATA_WIDTH-1:0] d0;
                    always @(posedge clk) begin
                        if (!rst_n) d0 <= 0;
                        else if (fsm_act_feed_en || fsm_compute_enable) d0 <= act_element;
                        else d0 <= 0;
                    end
                    assign skewed_act[DATA_WIDTH-1:0] = d0;
                end else begin : r_gt0
                    reg signed [DATA_WIDTH-1:0] sh [0:r];
                    always @(posedge clk) begin
                        if (!rst_n) sh[0] <= 0;
                        else if (fsm_act_feed_en || fsm_compute_enable) sh[0] <= act_element;
                        else sh[0] <= 0;
                    end
                    for (sk = 1; sk <= r; sk = sk + 1) begin : stages
                        always @(posedge clk) begin
                            if (!rst_n) sh[sk] <= 0;
                            else if (fsm_act_feed_en || fsm_compute_enable) sh[sk] <= sh[sk-1];
                            else sh[sk] <= 0;
                        end
                    end
                    assign skewed_act[(r*DATA_WIDTH) +: DATA_WIDTH] = sh[r];
                end
            end

            // 4×4 Systolic Core
            wire signed [TILE_SIZE*ACC_WIDTH-1:0] psum_out;
            wire [TILE_SIZE*TILE_SIZE-1:0]        zero_flags;

            systolic_array_core #(
                .ARRAY_SIZE(TILE_SIZE), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
            ) u_core (
                .clk(clk), .rst_n(rst_n),
                .compute_enable(fsm_compute_enable),
                .weight_load_en(fsm_weight_load_en),
                .acc_clear(fsm_acc_clear),
                .weight_in_flat(tile_weight_out),
                .act_in_flat(skewed_act),
                .psum_out_flat(psum_out),
                .zero_flags(zero_flags)
            );

            // Output Collector
            wire signed [TILE_SIZE*ACC_WIDTH-1:0] collected_result;
            wire                                  collected_valid;

            output_collector #(
                .ARRAY_SIZE(TILE_SIZE), .ACC_WIDTH(ACC_WIDTH)
            ) u_collector (
                .clk(clk), .rst_n(rst_n),
                .drain_enable(fsm_drain_enable),
                .psum_in_flat(psum_out),
                .result_flat(collected_result),
                .result_valid(collected_valid)
            );

            // Connect to shared arbiter bus
            assign tile_result_valid[t] = collected_valid;
            assign tile_result_flat[t*TILE_SIZE*ACC_WIDTH +: TILE_SIZE*ACC_WIDTH] = collected_result;
        end
    endgenerate

    
    nmu_output_shared #(
        .NUM_TILES(2),
        .ARRAY_SIZE(TILE_SIZE),
        .ACC_WIDTH(ACC_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .SRAM_DEPTH(SRAM_DEPTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_shared_nmu_output (
        .clk(clk), .rst_n(rst_n),
        .tile_result_valid(tile_result_valid),
        .tile_result_flat(tile_result_flat),
        .tile_grant(tile_grant),
        .bias_flat(bias_flat),
        .activation_mode(activation_mode),
        .leaky_shift(leaky_shift),
        .quantize_shift(quantize_shift),
        .pooling_enable(pooling_enable),
        .post_proc_enable(1'b1),
        .out_raddr(out_raddr),
        .out_rdata(out_rdata),
        .output_valid(output_valid),
        .output_count(output_count)
    );


    assign busy = tile_busy[0] | tile_busy[1];
    assign done = tile_done[0] & tile_done[1];

    reg [31:0] total_cycle_cnt;
    reg [31:0] active_cycle_cnt;
    reg [31:0] t0_computes;
    reg [31:0] t1_computes;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_cycle_cnt  <= 0;
            active_cycle_cnt <= 0;
            t0_computes      <= 0;
            t1_computes      <= 0;
        end else begin
            if (busy) total_cycle_cnt <= total_cycle_cnt + 1;
            if (tile_busy[0] || tile_busy[1]) active_cycle_cnt <= active_cycle_cnt + 1;
            if (tile_busy[0]) t0_computes <= t0_computes + 1;
            if (tile_busy[1]) t1_computes <= t1_computes + 1;
        end
    end

    assign perf_total_cycles   = total_cycle_cnt;
    assign perf_active_cycles  = active_cycle_cnt;
    assign perf_tile0_computes = t0_computes;
    assign perf_tile1_computes = t1_computes;

endmodule
