`timescale 1ns / 1ps

// =============================================================================
// Module:      near_memory_input
// Description: NMU input unit. Weight and activation operands in on-chip
//              Block RAM, with zero detection on the activation row fed to
//              the array.
//
//              - Two banks each (A/B) for weights and activations,
//                SRAM_DEPTH x (ARRAY_SIZE*DATA_WIDTH) bits
//              - Synchronous read, 1-cycle latency
//              - buffer_swap toggles the active bank. Host writes and array
//                reads both go to the active bank; controller_fsm does not
//                pulse buffer_swap yet, so load/compute overlap is not used.
// =============================================================================
module near_memory_input #(
    parameter ARRAY_SIZE  = 8,
    parameter DATA_WIDTH  = 8,
    parameter SRAM_DEPTH  = 256,
    parameter ADDR_WIDTH  = 8
)(
    input  wire                                    clk,
    input  wire                                    rst_n,
    // Control from FSM
    input  wire                                    load_weights,     // FSM reading weights from SRAM
    input  wire                                    load_activations, // FSM reading activations from SRAM
    input  wire                                    compute_start,    // begin feeding data to array
    input  wire                                    buffer_swap,      // swap active/shadow buffer

    // External write port — shared address and data bus
    input  wire [ADDR_WIDTH-1:0]                   ext_waddr,
    input  wire [ARRAY_SIZE*DATA_WIDTH-1:0]        ext_wdata,

    // Separate write enables for weight and activation SRAMs
    input  wire                                    ext_weight_we,    // write to weight SRAM
    input  wire                                    ext_act_we,       // write to activation SRAM

    // Weight read output
    output wire signed [ARRAY_SIZE*DATA_WIDTH-1:0] weight_out_flat,
    input  wire [ADDR_WIDTH-1:0]                   weight_raddr,

    // Activation read output
    output wire signed [ARRAY_SIZE*DATA_WIDTH-1:0] act_out_flat,
    input  wire [ADDR_WIDTH-1:0]                   act_raddr,

    // Zero detection output
    output wire [ARRAY_SIZE-1:0]                   act_zero_flags
);

    reg buffer_sel; // 0: A active/B shadow, 1: B active/A shadow

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer_sel <= 1'b0;
        end else if (buffer_swap) begin
            buffer_sel <= ~buffer_sel;
        end
    end

    // Internal wires for SRAM banks
    wire [ARRAY_SIZE*DATA_WIDTH-1:0] weight_out_A, weight_out_B;
    wire [ARRAY_SIZE*DATA_WIDTH-1:0] act_out_A, act_out_B;

    // Write to ACTIVE bank (buffer_sel=0 → A is active, buffer_sel=1 → B is active)
    wire we_weight_A = ext_weight_we & ~buffer_sel;
    wire we_weight_B = ext_weight_we &  buffer_sel;
    wire we_act_A    = ext_act_we    & ~buffer_sel;
    wire we_act_B    = ext_act_we    &  buffer_sel;

    // Weight Bank A
    sram_bank #(
        .DATA_WIDTH(ARRAY_SIZE*DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .SRAM_DEPTH(SRAM_DEPTH)
    ) weight_bank_A (
        .clk(clk),
        .we(we_weight_A),
        .waddr(ext_waddr),
        .wdata(ext_wdata),
        .raddr(weight_raddr),
        .rdata(weight_out_A)
    );

    // Weight Bank B
    sram_bank #(
        .DATA_WIDTH(ARRAY_SIZE*DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .SRAM_DEPTH(SRAM_DEPTH)
    ) weight_bank_B (
        .clk(clk),
        .we(we_weight_B),
        .waddr(ext_waddr),
        .wdata(ext_wdata),
        .raddr(weight_raddr),
        .rdata(weight_out_B)
    );

    // Act Bank A
    sram_bank #(
        .DATA_WIDTH(ARRAY_SIZE*DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .SRAM_DEPTH(SRAM_DEPTH)
    ) act_bank_A (
        .clk(clk),
        .we(we_act_A),
        .waddr(ext_waddr),
        .wdata(ext_wdata),
        .raddr(act_raddr),
        .rdata(act_out_A)
    );

    // Act Bank B
    sram_bank #(
        .DATA_WIDTH(ARRAY_SIZE*DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .SRAM_DEPTH(SRAM_DEPTH)
    ) act_bank_B (
        .clk(clk),
        .we(we_act_B),
        .waddr(ext_waddr),
        .wdata(ext_wdata),
        .raddr(act_raddr),
        .rdata(act_out_B)
    );

    // Output Muxes — read from active bank
    assign weight_out_flat = buffer_sel ? weight_out_B : weight_out_A;
    assign act_out_flat    = buffer_sel ? act_out_B    : act_out_A;

    // Zero detection
    genvar i;
    generate
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : ZERO_DET
            assign act_zero_flags[i] = (act_out_flat[i*DATA_WIDTH +: DATA_WIDTH] == {DATA_WIDTH{1'b0}});
        end
    endgenerate

endmodule
