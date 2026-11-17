`timescale 1ns / 1ps

module axi_nmu_wrapper #(
    parameter ARRAY_SIZE    = 8,
    parameter DATA_WIDTH    = 8,
    parameter ACC_WIDTH     = 32,
    parameter OUTPUT_WIDTH  = 16,
    parameter SRAM_DEPTH    = 256,
    parameter ADDR_WIDTH    = 8,
    parameter CFG_ADDR_WIDTH = 4,

    // AXI Parameters (derived, do not override)
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 7,
    parameter C_AXIS_TDATA_WIDTH = ARRAY_SIZE * ACC_WIDTH,   // 256 bits for 8×32
    parameter C_M_AXIS_TDATA_WIDTH = ARRAY_SIZE * OUTPUT_WIDTH // 128 bits for 8×16
)(
    
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_lite_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi_lite:s_axis:m_axis, ASSOCIATED_RESET s_axi_lite_aresetn" *)
    input  wire                              s_axi_lite_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_lite_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                              s_axi_lite_aresetn,
    // Write address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_lite_awaddr,
    input  wire [2:0]                        s_axi_lite_awprot,
    input  wire                              s_axi_lite_awvalid,
    output reg                               s_axi_lite_awready,
    // Write data channel
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_lite_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]   s_axi_lite_wstrb,
    input  wire                              s_axi_lite_wvalid,
    output reg                               s_axi_lite_wready,
    // Write response channel
    output reg  [1:0]                        s_axi_lite_bresp,
    output reg                               s_axi_lite_bvalid,
    input  wire                              s_axi_lite_bready,
    // Read address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_lite_araddr,
    input  wire [2:0]                        s_axi_lite_arprot,
    input  wire                              s_axi_lite_arvalid,
    output reg                               s_axi_lite_arready,
    // Read data channel
    output reg  [C_S_AXI_DATA_WIDTH-1:0]     s_axi_lite_rdata,
    output reg  [1:0]                        s_axi_lite_rresp,
    output reg                               s_axi_lite_rvalid,
    input  wire                              s_axi_lite_rready,

    input  wire [C_AXIS_TDATA_WIDTH-1:0]     s_axis_tdata,
    input  wire [1:0]                        s_axis_tuser,   // 00=weight, 01=act, 10=bias
    input  wire                              s_axis_tlast,
    input  wire                              s_axis_tvalid,
    output reg                               s_axis_tready,

    
    output wire [C_M_AXIS_TDATA_WIDTH-1:0]   m_axis_tdata,
    output reg                               m_axis_tlast,
    output reg                               m_axis_tvalid,
    input  wire                              m_axis_tready,

    output wire                              irq_done
);

   
    wire clk   = s_axi_lite_aclk;
    wire rst_n = s_axi_lite_aresetn;


    reg                              core_cfg_we;
    reg  [CFG_ADDR_WIDTH-1:0]        core_cfg_addr;
    reg  [31:0]                      core_cfg_wdata;
    reg  [CFG_ADDR_WIDTH-1:0]        core_cfg_raddr;
    wire [31:0]                      core_cfg_rdata;

    reg  [ADDR_WIDTH-1:0]            core_ext_waddr;
    reg  [ARRAY_SIZE*DATA_WIDTH-1:0] core_ext_wdata;
    reg                              core_ext_weight_we;
    reg                              core_ext_act_we;

    reg  [ADDR_WIDTH-1:0]            core_bias_waddr;
    reg  signed [ARRAY_SIZE*ACC_WIDTH-1:0] core_bias_wdata;
    reg                              core_bias_we;

    reg  [ADDR_WIDTH-1:0]            core_out_raddr;
    wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0] core_out_rdata;

    wire                             core_busy;
    wire                             core_done;
    wire                             core_output_valid;
    wire [ADDR_WIDTH-1:0]            core_output_count;

    // Perf counter wires (read via config_regs internally)
    wire [31:0] perf_total, perf_sram_rd, perf_sram_wr;
    wire [31:0] perf_compute, perf_stall, perf_zero_skip;

    // AXI read word-address (byte addr >> 2)
    wire [4:0] axi_rd_word_addr;
    wire [4:0] axi_wr_word_addr;
    assign axi_rd_word_addr = axi_araddr[6:2];
    assign axi_wr_word_addr = axi_awaddr[6:2];

  
    systolic_nmu_top #(
        .ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH), .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .SRAM_DEPTH(SRAM_DEPTH), .ADDR_WIDTH(ADDR_WIDTH),
        .CFG_ADDR_WIDTH(CFG_ADDR_WIDTH)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(core_cfg_we), .cfg_addr(core_cfg_addr),
        .cfg_wdata(core_cfg_wdata), .cfg_raddr(core_cfg_raddr),
        .cfg_rdata(core_cfg_rdata),
        .ext_waddr(core_ext_waddr), .ext_wdata(core_ext_wdata),
        .ext_weight_we(core_ext_weight_we), .ext_act_we(core_ext_act_we),
        .bias_waddr(core_bias_waddr), .bias_wdata(core_bias_wdata),
        .bias_we(core_bias_we),
        .out_raddr(core_out_raddr), .out_rdata(core_out_rdata),
        .busy(core_busy), .done(core_done),
        .output_valid(core_output_valid), .output_count(core_output_count),
        .perf_total_cycles(perf_total),
        .perf_sram_read_count(perf_sram_rd),
        .perf_sram_write_count(perf_sram_wr),
        .perf_compute_active_cycles(perf_compute),
        .perf_stall_cycles(perf_stall),
        .perf_zero_skip_count(perf_zero_skip)
    );

    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg aw_en;  // write address handshake tracker

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_lite_awready <= 1'b0;
            aw_en              <= 1'b1;
            axi_awaddr         <= 0;
        end else begin
            if (~s_axi_lite_awready && s_axi_lite_awvalid && s_axi_lite_wvalid && aw_en) begin
                s_axi_lite_awready <= 1'b1;
                aw_en              <= 1'b0;
                axi_awaddr         <= s_axi_lite_awaddr;
            end else if (s_axi_lite_bready && s_axi_lite_bvalid) begin
                aw_en              <= 1'b1;
                s_axi_lite_awready <= 1'b0;
            end else begin
                s_axi_lite_awready <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_lite_wready <= 1'b0;
        end else begin
            if (~s_axi_lite_wready && s_axi_lite_wvalid && s_axi_lite_awvalid && aw_en)
                s_axi_lite_wready <= 1'b1;
            else
                s_axi_lite_wready <= 1'b0;
        end
    end

    // Translate AXI writes to config_regs writes
    // AXI byte-addresses → config_regs word-addresses: addr[6:2]
    wire axi_wr_en = s_axi_lite_awready && s_axi_lite_awvalid &&
                     s_axi_lite_wready  && s_axi_lite_wvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            core_cfg_we    <= 1'b0;
            core_cfg_addr  <= 0;
            core_cfg_wdata <= 0;
        end else begin
            core_cfg_we <= 1'b0; // default: single-cycle pulse
            if (axi_wr_en) begin
                core_cfg_we    <= 1'b1;
                core_cfg_addr  <= axi_awaddr[6:2]; // word-aligned
                core_cfg_wdata <= s_axi_lite_wdata;
            end
        end
    end

    // Write response
    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_lite_bvalid <= 1'b0;
            s_axi_lite_bresp  <= 2'b00;
        end else begin
            if (axi_wr_en && ~s_axi_lite_bvalid) begin
                s_axi_lite_bvalid <= 1'b1;
                s_axi_lite_bresp  <= 2'b00; // OKAY
            end else if (s_axi_lite_bready && s_axi_lite_bvalid) begin
                s_axi_lite_bvalid <= 1'b0;
            end
        end
    end

   
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_lite_arready <= 1'b0;
            axi_araddr         <= 0;
        end else begin
            if (~s_axi_lite_arready && s_axi_lite_arvalid) begin
                s_axi_lite_arready <= 1'b1;
                axi_araddr         <= s_axi_lite_araddr;
            end else begin
                s_axi_lite_arready <= 1'b0;
            end
        end
    end

    // Read data mux (register readback)
    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_lite_rvalid <= 1'b0;
            s_axi_lite_rresp  <= 2'b00;
            s_axi_lite_rdata  <= 0;
        end else begin
            if (s_axi_lite_arready && s_axi_lite_arvalid && ~s_axi_lite_rvalid) begin
                s_axi_lite_rvalid <= 1'b1;
                s_axi_lite_rresp  <= 2'b00; // OKAY

                case (axi_rd_word_addr)
                    5'd0:  s_axi_lite_rdata <= 32'd0; // START (write-only)
                    5'd9:  s_axi_lite_rdata <= {29'd0, core_output_valid, core_busy, done_flag}; // STATUS
                    5'd10: s_axi_lite_rdata <= {24'd0, out_rows};  // OUTPUT_COUNT
                    5'd11: s_axi_lite_rdata <= perf_total;
                    5'd12: s_axi_lite_rdata <= perf_sram_rd;
                    5'd13: s_axi_lite_rdata <= perf_sram_wr;
                    5'd14: s_axi_lite_rdata <= perf_compute;
                    5'd15: s_axi_lite_rdata <= perf_stall;
                    5'd16: s_axi_lite_rdata <= perf_zero_skip;
                    default: begin
                        // For config registers 1-8, read from config_regs
                        core_cfg_raddr    <= axi_rd_word_addr[CFG_ADDR_WIDTH-1:0];
                        s_axi_lite_rdata  <= core_cfg_rdata;
                    end
                endcase
            end else if (s_axi_lite_rvalid && s_axi_lite_rready) begin
                s_axi_lite_rvalid <= 1'b0;
            end
        end
    end


    // Address counters for weight/act/bias row writes
    reg [ADDR_WIDTH-1:0] stream_waddr;
    reg [ADDR_WIDTH-1:0] stream_bias_waddr;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axis_tready       <= 1'b1;
            core_ext_weight_we  <= 1'b0;
            core_ext_act_we     <= 1'b0;
            core_bias_we        <= 1'b0;
            core_ext_waddr      <= 0;
            core_ext_wdata      <= 0;
            core_bias_waddr     <= 0;
            core_bias_wdata     <= 0;
            stream_waddr        <= 0;
            stream_bias_waddr   <= 0;
        end else begin
            // Defaults
            core_ext_weight_we <= 1'b0;
            core_ext_act_we    <= 1'b0;
            core_bias_we       <= 1'b0;

            // Don't accept data while core is busy
            s_axis_tready <= ~core_busy;

            if (s_axis_tvalid && s_axis_tready) begin
                case (s_axis_tuser)
                    2'b00: begin // Weight row
                        core_ext_waddr     <= stream_waddr;
                        core_ext_wdata     <= s_axis_tdata[ARRAY_SIZE*DATA_WIDTH-1:0];
                        core_ext_weight_we <= 1'b1;
                        stream_waddr       <= s_axis_tlast ? {ADDR_WIDTH{1'b0}} : stream_waddr + 1;
                    end
                    2'b01: begin // Activation row
                        core_ext_waddr   <= stream_waddr;
                        core_ext_wdata   <= s_axis_tdata[ARRAY_SIZE*DATA_WIDTH-1:0];
                        core_ext_act_we  <= 1'b1;
                        stream_waddr     <= s_axis_tlast ? {ADDR_WIDTH{1'b0}} : stream_waddr + 1;
                    end
                    2'b10: begin // Bias row
                        core_bias_waddr  <= stream_bias_waddr;
                        core_bias_wdata  <= s_axis_tdata[ARRAY_SIZE*ACC_WIDTH-1:0];
                        core_bias_we     <= 1'b1;
                        stream_bias_waddr <= s_axis_tlast ? {ADDR_WIDTH{1'b0}} : stream_bias_waddr + 1;
                    end
                    default: ; // ignore
                endcase

                // Reset address counters on TLAST
                if (s_axis_tlast) begin
                    stream_waddr      <= 0;
                    stream_bias_waddr <= 0;
                end
            end
        end
    end

    // Output stream: rows counted here because core output_count clears after drain
    reg [ADDR_WIDTH-1:0] out_rows;
    reg                  done_flag;
    wire                 start_wr = core_cfg_we && (core_cfg_addr == 0) && core_cfg_wdata[0];

    always @(posedge clk) begin
        if (!rst_n) begin
            out_rows  <= 0;
            done_flag <= 1'b0;
        end else if (start_wr) begin
            out_rows  <= 0;
            done_flag <= 1'b0;
        end else begin
            if (core_output_valid) out_rows <= out_rows + 1;
            if (core_done)         done_flag <= 1'b1;
        end
    end

    reg [ADDR_WIDTH-1:0] rd_addr;
    reg [1:0]            out_state;
    localparam OUT_IDLE = 2'd0;
    localparam OUT_ADDR = 2'd1;
    localparam OUT_WAIT = 2'd2;
    localparam OUT_SEND = 2'd3;

    assign m_axis_tdata = core_out_rdata;

    always @(posedge clk) begin
        if (!rst_n) begin
            out_state      <= OUT_IDLE;
            rd_addr        <= 0;
            core_out_raddr <= 0;
            m_axis_tvalid  <= 1'b0;
            m_axis_tlast   <= 1'b0;
        end else begin
            case (out_state)
                OUT_IDLE: if (core_done) begin
                    rd_addr   <= 0;
                    out_state <= OUT_ADDR;
                end
                OUT_ADDR: begin
                    core_out_raddr <= rd_addr;
                    out_state      <= OUT_WAIT;
                end
                OUT_WAIT: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= (rd_addr == out_rows - 1);
                    out_state     <= OUT_SEND;
                end
                OUT_SEND: if (m_axis_tready) begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    if (rd_addr == out_rows - 1) begin
                        out_state <= OUT_IDLE;
                    end else begin
                        rd_addr   <= rd_addr + 1;
                        out_state <= OUT_ADDR;
                    end
                end
            endcase
        end
    end

    reg core_done_d;
    always @(posedge clk) begin
        if (!rst_n) core_done_d <= 1'b0;
        else        core_done_d <= core_done;
    end
    assign irq_done = core_done & ~core_done_d;

endmodule
