`timescale 1ns / 1ps

module tb_axi_nmu;

 
    parameter ARRAY_SIZE    = 8;
    parameter DATA_WIDTH    = 8;
    parameter ACC_WIDTH     = 32;
    parameter OUTPUT_WIDTH  = 16;
    parameter SRAM_DEPTH    = 256;
    parameter ADDR_WIDTH    = 8;

    parameter CLK_PERIOD = 10;

    localparam N  = ARRAY_SIZE;
    localparam DW = DATA_WIDTH;
    localparam AW = ACC_WIDTH;
    localparam OW = OUTPUT_WIDTH;

    localparam C_S_AXI_ADDR_WIDTH  = 6;
    localparam C_S_AXI_DATA_WIDTH  = 32;
    localparam C_AXIS_TDATA_WIDTH  = N * AW;   // 256
    localparam C_M_AXIS_TDATA_WIDTH = N * OW;  // 128

    // AXI-Lite register byte addresses
    localparam REG_START      = 6'h00;
    localparam REG_MATRIX_M   = 6'h04;
    localparam REG_MATRIX_K   = 6'h08;
    localparam REG_MATRIX_N   = 6'h0C;
    localparam REG_ACT_MODE   = 6'h10;
    localparam REG_POOL_EN    = 6'h14;
    localparam REG_QUANT_SH   = 6'h18;
    localparam REG_LEAKY_SH   = 6'h1C;
    localparam REG_BIAS_BASE  = 6'h20;
    localparam REG_STATUS     = 6'h24;
    localparam REG_OUT_COUNT  = 6'h28;
    localparam REG_PERF_TOTAL = 6'h2C;

    
    reg clk;
    reg rst_n;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg  [C_S_AXI_ADDR_WIDTH-1:0]  awaddr;
    reg  [2:0]                     awprot;
    reg                            awvalid;
    wire                           awready;
    reg  [C_S_AXI_DATA_WIDTH-1:0]  wdata;
    reg  [C_S_AXI_DATA_WIDTH/8-1:0] wstrb;
    reg                            wvalid;
    wire                           wready;
    wire [1:0]                     bresp;
    wire                           bvalid;
    reg                            bready;
    reg  [C_S_AXI_ADDR_WIDTH-1:0]  araddr;
    reg  [2:0]                     arprot;
    reg                            arvalid;
    wire                           arready;
    wire [C_S_AXI_DATA_WIDTH-1:0]  rdata;
    wire [1:0]                     rresp;
    wire                           rvalid;
    reg                            rready;

   
    reg  [C_AXIS_TDATA_WIDTH-1:0]  s_tdata;
    reg  [1:0]                     s_tuser;
    reg                            s_tlast;
    reg                            s_tvalid;
    wire                           s_tready;

    wire [C_M_AXIS_TDATA_WIDTH-1:0] m_tdata;
    wire                            m_tlast;
    wire                            m_tvalid;
    reg                             m_tready;

    // Interrupt
    wire irq_done;

 
    axi_nmu_wrapper #(
        .ARRAY_SIZE(N), .DATA_WIDTH(DW), .ACC_WIDTH(AW),
        .OUTPUT_WIDTH(OW), .SRAM_DEPTH(SRAM_DEPTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .s_axi_lite_aclk(clk),
        .s_axi_lite_aresetn(rst_n),
        .s_axi_lite_awaddr(awaddr), .s_axi_lite_awprot(awprot),
        .s_axi_lite_awvalid(awvalid), .s_axi_lite_awready(awready),
        .s_axi_lite_wdata(wdata), .s_axi_lite_wstrb(wstrb),
        .s_axi_lite_wvalid(wvalid), .s_axi_lite_wready(wready),
        .s_axi_lite_bresp(bresp), .s_axi_lite_bvalid(bvalid),
        .s_axi_lite_bready(bready),
        .s_axi_lite_araddr(araddr), .s_axi_lite_arprot(arprot),
        .s_axi_lite_arvalid(arvalid), .s_axi_lite_arready(arready),
        .s_axi_lite_rdata(rdata), .s_axi_lite_rresp(rresp),
        .s_axi_lite_rvalid(rvalid), .s_axi_lite_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tuser(s_tuser),
        .s_axis_tlast(s_tlast), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready),
        .m_axis_tdata(m_tdata), .m_axis_tlast(m_tlast),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .irq_done(irq_done)
    );


    reg signed [DW-1:0] mat_W [0:N-1][0:N-1];
    reg signed [DW-1:0] mat_A [0:N-1][0:N-1];
    reg signed [AW-1:0] bias  [0:N-1];
    integer i, j;
    integer err_cnt;


    initial begin
        $dumpfile("tb_axi_nmu.vcd");
        $dumpvars(0, tb_axi_nmu);
    end



    task axi_lite_write;
        input [C_S_AXI_ADDR_WIDTH-1:0] addr;
        input [C_S_AXI_DATA_WIDTH-1:0] data;
        begin
            @(negedge clk);
            awaddr  = addr;
            awprot  = 3'b000;
            awvalid = 1'b1;
            wdata   = data;
            wstrb   = 4'hF;
            wvalid  = 1'b1;
            bready  = 1'b1;

            // Wait for both handshakes
            wait(awready && wready);
            @(posedge clk); #1;
            awvalid = 1'b0;
            wvalid  = 1'b0;

            // Wait for write response
            wait(bvalid);
            @(posedge clk); #1;
            bready = 1'b0;
        end
    endtask

    task axi_lite_read;
        input  [C_S_AXI_ADDR_WIDTH-1:0] addr;
        output [C_S_AXI_DATA_WIDTH-1:0] data;
        begin
            @(negedge clk);
            araddr  = addr;
            arprot  = 3'b000;
            arvalid = 1'b1;
            rready  = 1'b1;

            wait(arready);
            @(posedge clk); #1;
            arvalid = 1'b0;

            wait(rvalid);
            data = rdata;
            @(posedge clk); #1;
            rready = 1'b0;
        end
    endtask

    task axis_send_row;
        input [C_AXIS_TDATA_WIDTH-1:0] data;
        input [1:0]                    tuser;
        input                          last;
        begin
            @(negedge clk);
            s_tdata  = data;
            s_tuser  = tuser;
            s_tlast  = last;
            s_tvalid = 1'b1;

            wait(s_tready);
            @(posedge clk); #1;
            s_tvalid = 1'b0;
            s_tlast  = 1'b0;
        end
    endtask

    reg [31:0] read_data;

    initial begin
        // Initialize
        rst_n   = 0;
        awaddr  = 0; awprot = 0; awvalid = 0;
        wdata   = 0; wstrb  = 0; wvalid  = 0; bready = 0;
        araddr  = 0; arprot = 0; arvalid = 0; rready = 0;
        s_tdata = 0; s_tuser = 0; s_tlast = 0; s_tvalid = 0;
        m_tready = 0;
        err_cnt  = 0;

        // Build identity matrix test
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                mat_W[i][j] = (i == j) ? 8'sd1 : 8'sd0;
                mat_A[i][j] = (i * N + j + 1);
            end
            bias[i] = 0;
        end

        // Reset
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        $display("=== TEST: AXI NMU Integration ===");


        $display("  Configuring via AXI-Lite...");
        axi_lite_write(REG_MATRIX_M,  N);
        axi_lite_write(REG_MATRIX_K,  N);
        axi_lite_write(REG_MATRIX_N,  N);
        axi_lite_write(REG_ACT_MODE,  0);  // bypass
        axi_lite_write(REG_POOL_EN,   0);  // no pooling
        axi_lite_write(REG_QUANT_SH,  0);  // no shift
        axi_lite_write(REG_LEAKY_SH,  3);
        axi_lite_write(REG_BIAS_BASE, 0);


        $display("  Loading weights via AXI-Stream...");
        for (i = 0; i < N; i = i + 1) begin
            begin : pack_weight
                reg [C_AXIS_TDATA_WIDTH-1:0] row_data;
                row_data = 0;
                for (j = 0; j < N; j = j + 1)
                    row_data[j*DW +: DW] = mat_W[i][j];
                axis_send_row(row_data, 2'b00, (i == N-1));
            end
        end


        $display("  Loading activations via AXI-Stream...");
        for (i = 0; i < N; i = i + 1) begin
            begin : pack_act
                reg [C_AXIS_TDATA_WIDTH-1:0] row_data;
                row_data = 0;
                for (j = 0; j < N; j = j + 1)
                    row_data[j*DW +: DW] = mat_A[i][j];
                axis_send_row(row_data, 2'b01, (i == N-1));
            end
        end


        $display("  Loading biases via AXI-Stream...");
        for (i = 0; i < N; i = i + 1) begin
            begin : pack_bias
                reg [C_AXIS_TDATA_WIDTH-1:0] row_data;
                row_data = 0;
                for (j = 0; j < N; j = j + 1)
                    row_data[j*AW +: AW] = bias[j];
                axis_send_row(row_data, 2'b10, (i == N-1));
            end
        end


        $display("  Starting computation...");
        axi_lite_write(REG_START, 1);


        $display("  Waiting for completion...");
        begin : wait_done
            integer timeout;
            timeout = 0;
            while (!irq_done && timeout < 10000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 10000) begin
                $display("  ERROR: Timeout!");
                err_cnt = err_cnt + 1;
            end else begin
                $display("  Done after %0d cycles", timeout);
            end
        end


        axi_lite_read(REG_STATUS, read_data);
        $display("  STATUS register = 0x%08h", read_data);
        if (read_data[0] !== 1'b1) begin
            $display("  ERROR: STATUS.done not set");
            err_cnt = err_cnt + 1;
        end

        axi_lite_read(REG_OUT_COUNT, read_data);
        $display("  OUTPUT_COUNT = %0d", read_data);
        if (read_data != N) begin
            $display("  ERROR: OUTPUT_COUNT expected %0d", N);
            err_cnt = err_cnt + 1;
        end

        axi_lite_read(REG_PERF_TOTAL, read_data);
        $display("  PERF_TOTAL_CYCLES = %0d", read_data);


        $display("  Reading output via AXI-Stream...");
        begin : read_output
            integer row_cnt;
            row_cnt = 0;
            m_tready = 1;
            while (row_cnt < N) begin
                @(posedge clk);
                if (m_tvalid && m_tready) begin
                    $display("  Output row %0d: 0x%032h %s",
                             row_cnt, m_tdata, m_tlast ? "(LAST)" : "");
                    for (j = 0; j < N; j = j + 1)
                        if ($signed(m_tdata[j*16 +: 16]) !== mat_A[row_cnt][j]) begin
                            $display("  ERROR: row %0d col %0d got %0d exp %0d",
                                     row_cnt, j, $signed(m_tdata[j*16 +: 16]), mat_A[row_cnt][j]);
                            err_cnt = err_cnt + 1;
                        end
                    if (m_tlast !== (row_cnt == N-1)) begin
                        $display("  ERROR: TLAST wrong on row %0d", row_cnt);
                        err_cnt = err_cnt + 1;
                    end
                    row_cnt = row_cnt + 1;
                end
            end
        end


        repeat(10) @(posedge clk);
        $display("");

        if (err_cnt == 0)
            $display("  AXI NMU TEST: PASSED");
        else
            $display("  AXI NMU TEST: FAILED (%0d errors)", err_cnt);


        $finish;
    end

    // Global timeout
    initial begin
        #(CLK_PERIOD * 200000);
        $display("FATAL: Global timeout");
        $finish;
    end

endmodule
