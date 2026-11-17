`timescale 1ns / 1ps

module nmu_output_shared #(
    parameter NUM_TILES     = 2,
    parameter ARRAY_SIZE    = 4,
    parameter ACC_WIDTH     = 32,
    parameter OUTPUT_WIDTH  = 16,
    parameter SRAM_DEPTH    = 256,
    parameter ADDR_WIDTH    = 8
)(
    input  wire                                         clk,
    input  wire                                         rst_n,

    // Results from each tile (active when tile's drain is valid)
    input  wire [NUM_TILES-1:0]                         tile_result_valid,
    input  wire [NUM_TILES*ARRAY_SIZE*ACC_WIDTH-1:0]    tile_result_flat,
    output reg  [NUM_TILES-1:0]                         tile_grant,

    // Bias values (shared across tiles)
    input  wire signed [ARRAY_SIZE*ACC_WIDTH-1:0]       bias_flat,

    // Configuration (shared)
    input  wire [1:0]                                   activation_mode,
    input  wire [3:0]                                   leaky_shift,
    input  wire [3:0]                                   quantize_shift,
    input  wire                                         pooling_enable,
    input  wire                                         post_proc_enable,

    // Output SRAM read interface
    input  wire [ADDR_WIDTH-1:0]                        out_raddr,
    output wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0]           out_rdata,

    // Status
    output wire                                         output_valid,
    output wire [ADDR_WIDTH-1:0]                        output_count
);

   
    reg [$clog2(NUM_TILES)-1:0] current_tile;
    reg [$clog2(NUM_TILES)-1:0] next_tile;
    reg                         arb_locked;  // locked to current tile during drain

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_tile <= 0;
            arb_locked   <= 1'b0;
        end else begin
            if (!arb_locked) begin
                // Find next tile with valid data (round-robin)
                if (tile_result_valid[next_tile]) begin
                    current_tile <= next_tile;
                    arb_locked   <= 1'b1;
                end
            end else begin
                // Unlock when current tile's drain completes
                if (!tile_result_valid[current_tile]) begin
                    arb_locked <= 1'b0;
                    next_tile  <= (current_tile + 1 < NUM_TILES) ?
                                  current_tile + 1 : 0;
                end
            end
        end
    end

    // Grant signals
    integer t;
    always @(*) begin
        for (t = 0; t < NUM_TILES; t = t + 1)
            tile_grant[t] = arb_locked && (current_tile == t);
    end

   
    wire                                    muxed_valid;
    wire signed [ARRAY_SIZE*ACC_WIDTH-1:0]  muxed_result;

    assign muxed_valid  = arb_locked ? tile_result_valid[current_tile] : 1'b0;
    assign muxed_result = tile_result_flat[current_tile*ARRAY_SIZE*ACC_WIDTH +: ARRAY_SIZE*ACC_WIDTH];

  
    near_memory_output #(
        .ARRAY_SIZE(ARRAY_SIZE), .ACC_WIDTH(ACC_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH), .SRAM_DEPTH(SRAM_DEPTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_shared_nmu (
        .clk(clk), .rst_n(rst_n),
        .result_valid(muxed_valid),
        .result_flat(muxed_result),
        .bias_flat(bias_flat),
        .activation_mode(activation_mode),
        .leaky_shift(leaky_shift),
        .quantize_shift(quantize_shift),
        .pooling_enable(pooling_enable),
        .post_proc_enable(post_proc_enable),
        .out_raddr(out_raddr),
        .out_rdata(out_rdata),
        .output_valid(output_valid),
        .output_count(output_count)
    );

endmodule
