`timescale 1ns / 1ps

module systolic_baseline_top #(
    parameter ARRAY_SIZE    = 8,
    parameter DATA_WIDTH    = 8,
    parameter ACC_WIDTH     = 32,
    parameter OUTPUT_WIDTH  = 16,
    parameter SRAM_DEPTH    = 256,
    parameter ADDR_WIDTH    = 8,
    parameter CFG_ADDR_WIDTH = 4
)(
    input  wire                                     clk,
    input  wire                                     rst_n,

    // --- Configuration Write Interface ---
    input  wire                                     cfg_we,
    input  wire [CFG_ADDR_WIDTH-1:0]                cfg_addr,
    input  wire [31:0]                              cfg_wdata,
    input  wire [CFG_ADDR_WIDTH-1:0]                cfg_raddr,
    output wire [31:0]                              cfg_rdata,

    // --- External Data Load Interface ---
    input  wire [ADDR_WIDTH-1:0]                    ext_waddr,
    input  wire [ARRAY_SIZE*DATA_WIDTH-1:0]         ext_wdata,
    input  wire                                     ext_weight_we,
    input  wire                                     ext_act_we,

    // --- Bias Load Interface ---
    input  wire [ADDR_WIDTH-1:0]                    bias_waddr,
    input  wire signed [ARRAY_SIZE*ACC_WIDTH-1:0]   bias_wdata,
    input  wire                                     bias_we,

    // --- Output Read Interface ---
    input  wire [ADDR_WIDTH-1:0]                    out_raddr,
    output wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0]       out_rdata,

    // --- Status ---
    output wire                                     busy,
    output wire                                     done,
    output wire                                     output_valid,
    output wire [ADDR_WIDTH-1:0]                    output_count,

    // --- Performance Counters (directly exposed for testbench comparison) ---
    output wire [31:0]                              perf_total_cycles,
    output wire [31:0]                              perf_sram_read_count,
    output wire [31:0]                              perf_sram_write_count,
    output wire [31:0]                              perf_compute_active_cycles,
    output wire [31:0]                              perf_stall_cycles,
    output wire [31:0]                              perf_zero_skip_count
);

  
    // Config outputs
    wire [15:0] matrix_m_size, matrix_k_size, matrix_n_size;
    wire [1:0]  activation_mode;
    wire        pooling_enable;
    wire [3:0]  quantize_shift, leaky_shift;
    wire        start_pulse;
    wire [15:0] bias_base_addr;

    // FSM control signals
    wire        fsm_weight_load_en;
    wire [ADDR_WIDTH-1:0] fsm_weight_load_addr;
    wire        fsm_weight_load_done;
    wire        fsm_act_feed_en;
    wire [ADDR_WIDTH-1:0] fsm_act_feed_addr;
    wire        fsm_compute_enable;
    wire        fsm_acc_clear;
    wire        fsm_drain_enable;
    wire        fsm_drain_done;
    wire        fsm_buffer_swap;

    // Baseline-specific FSM signals
    wire        fsm_pass_read_en;
    wire [ADDR_WIDTH-1:0] fsm_pass_read_addr;
    wire        fsm_pass_write_en;
    wire [ADDR_WIDTH-1:0] fsm_pass_write_addr;
    wire [ADDR_WIDTH-1:0] fsm_pass_addr;
    wire [2:0]  fsm_active_pass;
    wire [15:0] current_tile_m, current_tile_n, current_tile_k;

    // Performance counter events from FSM
    wire        fsm_perf_sram_rd;
    wire        fsm_perf_sram_wr;
    wire        fsm_perf_compute;

    // NMU Input outputs
    wire signed [ARRAY_SIZE*DATA_WIDTH-1:0] nmu_weight_out;
    wire signed [ARRAY_SIZE*DATA_WIDTH-1:0] nmu_act_out;
    wire [ARRAY_SIZE-1:0]                   nmu_act_zero_flags;

    // Input skew
    wire signed [ARRAY_SIZE*DATA_WIDTH-1:0] skewed_act_flat;

    // Systolic array core outputs
    wire signed [ARRAY_SIZE*ACC_WIDTH-1:0]  core_psum_out;
    wire [ARRAY_SIZE-1:0]                   core_zero_flags;

    // Output collector
    wire signed [ARRAY_SIZE*ACC_WIDTH-1:0]  collector_result;
    wire                                    collector_result_valid;

    // Bias SRAM
    (* ram_style = "block" *)
    reg signed [ARRAY_SIZE*ACC_WIDTH-1:0] bias_sram [0:SRAM_DEPTH-1];
    reg signed [ARRAY_SIZE*ACC_WIDTH-1:0] bias_data_reg;
    reg [ADDR_WIDTH-1:0] bias_raddr_reg;
    wire [ADDR_WIDTH-1:0] bias_raddr_next;

    // Intermediate SRAM (32-bit wide, for raw psums between passes)
    (* ram_style = "block" *)
    reg signed [ARRAY_SIZE*ACC_WIDTH-1:0] inter_sram [0:SRAM_DEPTH-1];
    reg signed [ARRAY_SIZE*ACC_WIDTH-1:0] inter_rdata_reg;
    reg [ADDR_WIDTH-1:0] inter_waddr_cnt;

    // Post-processing stage wires
    wire                                      bias_valid_out;
    wire signed [ARRAY_SIZE*ACC_WIDTH-1:0]    bias_data_out;
    wire                                      act_valid_out;
    wire signed [ARRAY_SIZE*ACC_WIDTH-1:0]    act_data_out;
    wire                                      quant_valid_out;
    wire signed [ARRAY_SIZE*OUTPUT_WIDTH-1:0] quant_data_out;

    // Output SRAM
    (* ram_style = "block" *)
    reg [ARRAY_SIZE*OUTPUT_WIDTH-1:0] out_sram [0:SRAM_DEPTH-1];
    reg [ARRAY_SIZE*OUTPUT_WIDTH-1:0] out_sram_rdata_reg;
    reg [ADDR_WIDTH-1:0] out_waddr_cnt;
    reg                  out_valid_reg;

    
    config_regs #(.ADDR_WIDTH(CFG_ADDR_WIDTH)) u_config_regs (
        .clk(clk), .rst_n(rst_n), .cfg_we(cfg_we), .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata), .cfg_raddr(cfg_raddr), .cfg_rdata(cfg_rdata),
        .matrix_m_size(matrix_m_size), .matrix_k_size(matrix_k_size),
        .matrix_n_size(matrix_n_size), .activation_mode(activation_mode),
        .pooling_enable(pooling_enable), .quantize_shift(quantize_shift),
        .leaky_shift(leaky_shift), .start_pulse(start_pulse),
        .bias_base_addr(bias_base_addr),
        .perf_total_cycles(perf_total_cycles),
        .perf_sram_read_count(perf_sram_read_count),
        .perf_sram_write_count(perf_sram_write_count),
        .perf_compute_active_cycles(perf_compute_active_cycles),
        .perf_stall_cycles(perf_stall_cycles),
        .perf_zero_skip_count(perf_zero_skip_count)
    );


    baseline_multipass_fsm #(
        .ARRAY_SIZE(ARRAY_SIZE), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_fsm (
        .clk(clk), .rst_n(rst_n),
        .start(start_pulse), .done(done), .busy(busy),
        .matrix_m_size(matrix_m_size), .matrix_k_size(matrix_k_size),
        .matrix_n_size(matrix_n_size),
        .weight_load_en(fsm_weight_load_en), .weight_load_addr(fsm_weight_load_addr),
        .weight_load_done(fsm_weight_load_done),
        .act_feed_en(fsm_act_feed_en), .act_feed_addr(fsm_act_feed_addr),
        .compute_enable(fsm_compute_enable), .acc_clear(fsm_acc_clear),
        .drain_enable(fsm_drain_enable), .drain_done(fsm_drain_done),
        .buffer_swap(fsm_buffer_swap),
        .pass_read_en(fsm_pass_read_en), .pass_read_addr(fsm_pass_read_addr),
        .pass_write_en(fsm_pass_write_en), .pass_write_addr(fsm_pass_write_addr),
        .pass_addr(fsm_pass_addr), .active_pass(fsm_active_pass),
        .current_tile_m(current_tile_m), .current_tile_n(current_tile_n),
        .current_tile_k(current_tile_k),
        .perf_sram_rd_event(fsm_perf_sram_rd),
        .perf_sram_wr_event(fsm_perf_sram_wr),
        .perf_compute_active(fsm_perf_compute)
    );

    near_memory_input #(
        .ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH),
        .SRAM_DEPTH(SRAM_DEPTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_near_memory_input (
        .clk(clk), .rst_n(rst_n),
        .load_weights(fsm_weight_load_en), .load_activations(fsm_act_feed_en),
        .compute_start(fsm_compute_enable), .buffer_swap(fsm_buffer_swap),
        .ext_waddr(ext_waddr), .ext_wdata(ext_wdata),
        .ext_weight_we(ext_weight_we), .ext_act_we(ext_act_we),
        .weight_out_flat(nmu_weight_out), .weight_raddr(fsm_weight_load_addr),
        .act_out_flat(nmu_act_out), .act_raddr(fsm_act_feed_addr),
        .act_zero_flags(nmu_act_zero_flags)
    );


    genvar row_idx, s;
    generate
        for (row_idx = 0; row_idx < ARRAY_SIZE; row_idx = row_idx + 1) begin : gen_skew
            wire signed [DATA_WIDTH-1:0] row_act_in;
            assign row_act_in = nmu_act_out[(row_idx*DATA_WIDTH) +: DATA_WIDTH];
            if (row_idx == 0) begin : no_skew
                reg signed [DATA_WIDTH-1:0] delay_reg;
                always @(posedge clk) begin
                    if (!rst_n)                                    delay_reg <= {DATA_WIDTH{1'b0}};
                    else if (fsm_act_feed_en || fsm_compute_enable) delay_reg <= row_act_in;
                    else                                           delay_reg <= {DATA_WIDTH{1'b0}};
                end
                assign skewed_act_flat[DATA_WIDTH-1:0] = delay_reg;
            end else begin : with_skew
                reg signed [DATA_WIDTH-1:0] shift_reg [0:row_idx];
                always @(posedge clk) begin
                    if (!rst_n)                                    shift_reg[0] <= {DATA_WIDTH{1'b0}};
                    else if (fsm_act_feed_en || fsm_compute_enable) shift_reg[0] <= row_act_in;
                    else                                           shift_reg[0] <= {DATA_WIDTH{1'b0}};
                end
                for (s = 1; s <= row_idx; s = s + 1) begin : shift_stages
                    always @(posedge clk) begin
                        if (!rst_n)                                    shift_reg[s] <= {DATA_WIDTH{1'b0}};
                        else if (fsm_act_feed_en || fsm_compute_enable) shift_reg[s] <= shift_reg[s-1];
                        else                                           shift_reg[s] <= {DATA_WIDTH{1'b0}};
                    end
                end
                assign skewed_act_flat[(row_idx*DATA_WIDTH) +: DATA_WIDTH] = shift_reg[row_idx];
            end
        end
    endgenerate

   
    systolic_array_core #(
        .ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) u_systolic_array_core (
        .clk(clk), .rst_n(rst_n), .compute_enable(fsm_compute_enable),
        .weight_load_en(fsm_weight_load_en), .acc_clear(fsm_acc_clear),
        .weight_in_flat(nmu_weight_out), .act_in_flat(skewed_act_flat),
        .psum_out_flat(core_psum_out), .zero_flags(core_zero_flags)
    );


    output_collector #(.ARRAY_SIZE(ARRAY_SIZE), .ACC_WIDTH(ACC_WIDTH)) u_output_collector (
        .clk(clk), .rst_n(rst_n), .drain_enable(fsm_drain_enable),
        .psum_in_flat(core_psum_out), .result_flat(collector_result),
        .result_valid(collector_result_valid)
    );

    integer bi;
    initial for (bi = 0; bi < SRAM_DEPTH; bi = bi + 1) bias_sram[bi] = {(ARRAY_SIZE*ACC_WIDTH){1'b0}};

    always @(posedge clk) begin
        if (bias_we)
            bias_sram[bias_waddr] <= bias_wdata;
        if (fsm_pass_read_en && (fsm_active_pass == 3'd1))
            bias_data_reg <= bias_sram[bias_base_addr[ADDR_WIDTH-1:0] + fsm_pass_read_addr];
    end

    // Pipeline register to match 1-cycle SRAM read latency
    reg pass_read_en_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pass_read_en_d1 <= 1'b0;
        else
            pass_read_en_d1 <= fsm_pass_read_en;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || fsm_acc_clear) begin
            inter_waddr_cnt <= {ADDR_WIDTH{1'b0}};
        end else if (collector_result_valid) begin
            inter_waddr_cnt <= inter_waddr_cnt + 1'b1;
        end
    end

    // Inter SRAM Port A: Write
    always @(posedge clk) begin
        if (collector_result_valid) begin
            inter_sram[inter_waddr_cnt] <= collector_result;
        end else if (fsm_pass_write_en) begin
            case (fsm_active_pass)
                3'd1: inter_sram[fsm_pass_write_addr] <= bias_data_out;
                3'd2: inter_sram[fsm_pass_write_addr] <= act_data_out;
                3'd3: inter_sram[fsm_pass_write_addr] <= {{(ARRAY_SIZE*ACC_WIDTH - ARRAY_SIZE*OUTPUT_WIDTH){1'b0}}, quant_data_out};
                default: ;
            endcase
        end
    end

    // Inter SRAM Port B: Read
    always @(posedge clk) begin
        if (fsm_pass_read_en) begin
            inter_rdata_reg <= inter_sram[fsm_pass_read_addr];
        end
    end


    // --- Bias Adder (active during S_BIAS_PASS) ---
    bias_adder #(.ARRAY_SIZE(ARRAY_SIZE), .ACC_WIDTH(ACC_WIDTH)) u_bias_adder (
        .clk(clk), .rst_n(rst_n),
        .enable(fsm_active_pass == 3'd1),
        .valid_in(pass_read_en_d1 && (fsm_active_pass == 3'd1)),
        .data_in_flat(inter_rdata_reg),
        .bias_flat(bias_data_reg),
        .valid_out(bias_valid_out),
        .data_out_flat(bias_data_out)
    );

    // --- Activation Unit (active during S_ACT_PASS) ---
    activation_unit #(.ARRAY_SIZE(ARRAY_SIZE), .ACC_WIDTH(ACC_WIDTH)) u_activation (
        .clk(clk), .rst_n(rst_n),
        .mode(fsm_active_pass == 3'd2 ? activation_mode : 2'b00),
        .leaky_shift(leaky_shift),
        .valid_in(pass_read_en_d1 && (fsm_active_pass == 3'd2)),
        .data_in_flat(inter_rdata_reg),
        .valid_out(act_valid_out),
        .data_out_flat(act_data_out)
    );

    // --- Quantizer (active during S_QUANT_PASS) ---
    quantizer #(
        .ARRAY_SIZE(ARRAY_SIZE), .ACC_WIDTH(ACC_WIDTH), .OUTPUT_WIDTH(OUTPUT_WIDTH)
    ) u_quantizer (
        .clk(clk), .rst_n(rst_n),
        .shift_amount(fsm_active_pass == 3'd3 ? quantize_shift : 4'd0),
        .valid_in(pass_read_en_d1 && (fsm_active_pass == 3'd3)),
        .data_in_flat(inter_rdata_reg),
        .valid_out(quant_valid_out),
        .data_out_flat(quant_data_out)
    );

    // --- Pooling Unit (active during S_POOL_PASS) ---
    wire pool_valid_out;
    wire signed [(ARRAY_SIZE/2)*OUTPUT_WIDTH-1:0] pool_data_out;
    wire signed [ARRAY_SIZE*OUTPUT_WIDTH-1:0] pool_bypass_out;

    pooling_unit #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .OUTPUT_WIDTH(OUTPUT_WIDTH)
    ) u_baseline_pooling (
        .clk(clk), .rst_n(rst_n),
        .enable(pooling_enable && (fsm_active_pass == 3'd4)),
        .valid_in(pass_read_en_d1 && (fsm_active_pass == 3'd4)),
        .data_in_flat(inter_rdata_reg[ARRAY_SIZE*OUTPUT_WIDTH-1:0]),
        .valid_out(pool_valid_out),
        .data_out_flat(pool_data_out),
        .data_bypass_flat(pool_bypass_out)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_waddr_cnt <= {ADDR_WIDTH{1'b0}};
            out_valid_reg <= 1'b0;
        end else begin
            out_valid_reg <= 1'b0;

            if (fsm_pass_write_en && (fsm_active_pass == 3'd4)) begin
                out_sram[fsm_pass_write_addr] <= (pooling_enable) ?
                    {{(ARRAY_SIZE/2*OUTPUT_WIDTH){1'b0}}, pool_data_out} :
                    pool_bypass_out;
                out_waddr_cnt <= fsm_pass_write_addr + 1'b1;
                out_valid_reg <= 1'b1;
            end

            if (fsm_acc_clear)
                out_waddr_cnt <= {ADDR_WIDTH{1'b0}};
        end
    end

    // Output SRAM read port
    always @(posedge clk) begin
        out_sram_rdata_reg <= out_sram[out_raddr];
    end

    assign out_rdata    = out_sram_rdata_reg;
    assign output_valid = out_valid_reg;
    assign output_count = out_waddr_cnt;

   
    performance_counters u_perf_counters (
        .clk(clk), .rst_n(rst_n),
        .clear(start_pulse),
        .counting_enable(busy),
        .sram_read_event(fsm_perf_sram_rd),
        .sram_write_event(fsm_perf_sram_wr),
        .compute_active(fsm_perf_compute),
        .stall_event(1'b0),
        .zero_skip_event(|core_zero_flags & fsm_compute_enable),
        .total_cycles(perf_total_cycles),
        .sram_read_count(perf_sram_read_count),
        .sram_write_count(perf_sram_write_count),
        .compute_active_cycles(perf_compute_active_cycles),
        .stall_cycles(perf_stall_cycles),
        .zero_skip_count(perf_zero_skip_count)
    );

endmodule
