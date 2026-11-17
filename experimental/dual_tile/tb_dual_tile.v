`timescale 1ns / 1ps

module tb_dual_tile;

    parameter TILE_SIZE      = 4;
    parameter DATA_WIDTH     = 8;
    parameter ACC_WIDTH      = 32;
    parameter OUTPUT_WIDTH   = 16;
    parameter SRAM_DEPTH     = 256;
    parameter ADDR_WIDTH     = 8;
    parameter CFG_ADDR_WIDTH = 4;
    parameter CLK_PERIOD     = 10;

    reg                                     clk;
    reg                                     rst_n;

    // Config interface
    reg                                     cfg_we;
    reg  [CFG_ADDR_WIDTH-1:0]               cfg_addr;
    reg  [31:0]                             cfg_wdata;
    reg  [CFG_ADDR_WIDTH-1:0]               cfg_raddr;
    wire [31:0]                             cfg_rdata;

    // External write interface
    reg                                     ext_tile_sel;
    reg  [ADDR_WIDTH-1:0]                   ext_waddr;
    reg  [TILE_SIZE*DATA_WIDTH-1:0]         ext_wdata;
    reg                                     ext_weight_we;
    reg                                     ext_act_we;

    // Bias interface
    reg  [ADDR_WIDTH-1:0]                   bias_waddr;
    reg  signed [TILE_SIZE*ACC_WIDTH-1:0]   bias_wdata;
    reg                                     bias_we;

    // Output read interface
    reg  [ADDR_WIDTH-1:0]                   out_raddr;
    wire [TILE_SIZE*OUTPUT_WIDTH-1:0]       out_rdata;

    // Status
    wire                                    busy;
    wire                                    done;
    wire                                    output_valid;
    wire [ADDR_WIDTH-1:0]                   output_count;

    // Telemetry
    wire [31:0]                             perf_total_cycles;
    wire [31:0]                             perf_active_cycles;
    wire [31:0]                             perf_tile0_computes;
    wire [31:0]                             perf_tile1_computes;

    systolic_dual_tile_top #(
        .TILE_SIZE(TILE_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .SRAM_DEPTH(SRAM_DEPTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .CFG_ADDR_WIDTH(CFG_ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_raddr(cfg_raddr), .cfg_rdata(cfg_rdata),
        .ext_tile_sel(ext_tile_sel),
        .ext_waddr(ext_waddr), .ext_wdata(ext_wdata),
        .ext_weight_we(ext_weight_we), .ext_act_we(ext_act_we),
        .bias_waddr(bias_waddr), .bias_wdata(bias_wdata), .bias_we(bias_we),
        .out_raddr(out_raddr), .out_rdata(out_rdata),
        .busy(busy), .done(done),
        .output_valid(output_valid), .output_count(output_count),
        .perf_total_cycles(perf_total_cycles),
        .perf_active_cycles(perf_active_cycles),
        .perf_tile0_computes(perf_tile0_computes),
        .perf_tile1_computes(perf_tile1_computes)
    );

    // Clock generator
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Helper task to write config register
    task write_cfg;
        input [CFG_ADDR_WIDTH-1:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            cfg_we    <= 1'b1;
            cfg_addr  <= addr;
            cfg_wdata <= data;
            @(posedge clk);
            cfg_we    <= 1'b0;
        end
    endtask

    integer i, errors;

    initial begin
        // Initialize signals
        rst_n         = 0;
        cfg_we        = 0;
        cfg_addr      = 0;
        cfg_wdata     = 0;
        cfg_raddr     = 0;
        ext_tile_sel  = 0;
        ext_waddr     = 0;
        ext_wdata     = 0;
        ext_weight_we = 0;
        ext_act_we    = 0;
        bias_waddr    = 0;
        bias_wdata    = 0;
        bias_we       = 0;
        out_raddr     = 0;
        errors        = 0;

        $display("  Dual-Tile Systolic Array with Shared NMU Output Testbench");
        $display("  Target: 2x 4x4 Tiles -> Shared NMU Arbiter Pipeline");


        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        // 1. Configure dimensions and post-processing
        $display("[Step 1] Configuring registers...");
        write_cfg(4'h1, 32'd4);  // M = 4
        write_cfg(4'h2, 32'd4);  // K = 4
        write_cfg(4'h3, 32'd4);  // N = 4
        write_cfg(4'h4, 32'd0);  // ReLU mode
        write_cfg(4'h5, 32'd0);  // Pooling disabled
        write_cfg(4'h6, 32'd0);  // Quant shift = 0
        write_cfg(4'h7, 32'd0);  // Leaky shift = 0
        write_cfg(4'h8, 32'd0);  // Bias base = 0

        // 2. Load Bias values
        $display("[Step 2] Loading shared bias vector...");
        @(posedge clk);
        bias_we    <= 1'b1;
        bias_waddr <= 8'd0;
        // Bias = +10 for all 4 channels
        bias_wdata <= {32'sd10, 32'sd10, 32'sd10, 32'sd10};
        @(posedge clk);
        bias_we    <= 1'b0;

        // 3. Load Tile 0 Weights & Activations (Matrix of 1s)
        $display("[Step 3] Loading Tile 0 matrices...");
        ext_tile_sel <= 1'b0;
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            ext_waddr     <= i;
            ext_wdata     <= {8'd1, 8'd1, 8'd1, 8'd1}; // 4x1s
            ext_weight_we <= 1'b1;
            ext_act_we    <= 1'b1;
        end
        @(posedge clk);
        ext_weight_we <= 1'b0;
        ext_act_we    <= 1'b0;

        // 4. Load Tile 1 Weights & Activations (Matrix of 2s)
        $display("[Step 4] Loading Tile 1 matrices...");
        ext_tile_sel <= 1'b1;
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            ext_waddr     <= i;
            ext_wdata     <= {8'd2, 8'd2, 8'd2, 8'd2}; // 4x2s
            ext_weight_we <= 1'b1;
            ext_act_we    <= 1'b1;
        end
        @(posedge clk);
        ext_weight_we <= 1'b0;
        ext_act_we    <= 1'b0;

        // 5. Start Execution
        $display("[Step 5] Triggering simultaneous dual-tile computation...");
        write_cfg(4'h0, 32'h00000001); // Start pulse

        // 6. Wait for completion
        $display("[Step 6] Waiting for both tiles and shared arbiter to finish...");
        wait(done == 1'b1);
        #(CLK_PERIOD * 10);

        $display("  Dual-Tile Execution Completed Successfully!");
        $display("  Total Cycles       : %0d", perf_total_cycles);
        $display("  Active Cycles      : %0d", perf_active_cycles);
        $display("  Tile 0 Active Time : %0d cycles", perf_tile0_computes);
        $display("  Tile 1 Active Time : %0d cycles", perf_tile1_computes);
        $display("  Output Count       : %0d elements", output_count);


        // 7. Verify Results from Shared Output SRAM
        $display("[Step 7] Reading results from shared NMU output SRAM...");
        for (i = 0; i < output_count && i < 8; i = i + 1) begin
            @(posedge clk);
            out_raddr <= i;
            @(posedge clk);
            @(posedge clk);
            $display("  SRAM[%0d] = %h (Word3: %0d, Word2: %0d, Word1: %0d, Word0: %0d)",
                     i, out_rdata,
                     out_rdata[63:48], out_rdata[47:32], out_rdata[31:16], out_rdata[15:0]);
        end

        $display("  NOTE: smoke test only, no golden check. Output rows: %0d", output_count);
   
        $finish;
    end

    // Safety timeout
    initial begin
        #(CLK_PERIOD * 5000);
        $display("[ERROR] Simulation timed out!");
        $finish;
    end

endmodule
