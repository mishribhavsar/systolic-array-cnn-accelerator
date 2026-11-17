`timescale 1ns / 1ps

module axi_nmu_baseline_wrapper #(
    parameter ARRAY_SIZE     = 8,
    parameter DATA_WIDTH     = 8,
    parameter ACC_WIDTH      = 32,
    parameter OUTPUT_WIDTH   = 16,
    parameter SRAM_DEPTH     = 256,
    parameter ADDR_WIDTH     = 8,
    parameter CFG_ADDR_WIDTH = 4,

    parameter C_S_AXI_DATA_WIDTH   = 32,
    parameter C_S_AXI_ADDR_WIDTH   = 7,
    parameter C_AXIS_TDATA_WIDTH   = ARRAY_SIZE * ACC_WIDTH,
    parameter C_M_AXIS_TDATA_WIDTH = ARRAY_SIZE * OUTPUT_WIDTH
)(
    // AXI4-Lite Slave Interface (Configuration)
    input  wire                              s_axi_lite_aclk,
    input  wire                              s_axi_lite_aresetn,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_lite_awaddr,
    input  wire [2:0]                        s_axi_lite_awprot,
    input  wire                              s_axi_lite_awvalid,
    output reg                               s_axi_lite_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_lite_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]   s_axi_lite_wstrb,
    input  wire                              s_axi_lite_wvalid,
    output reg                               s_axi_lite_wready,
    output reg  [1:0]                        s_axi_lite_bresp,
    output reg                               s_axi_lite_bvalid,
    input  wire                              s_axi_lite_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_lite_araddr,
    input  wire [2:0]                        s_axi_lite_arprot,
    input  wire                              s_axi_lite_arvalid,
    output reg                               s_axi_lite_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]     s_axi_lite_rdata,
    output reg  [1:0]                        s_axi_lite_rresp,
    output reg                               s_axi_lite_rvalid,
    input  wire                              s_axi_lite_rready,

    // AXI4-Stream Slave Interface (Input Data)
    input  wire [C_AXIS_TDATA_WIDTH-1:0]     s_axis_tdata,
    input  wire [1:0]                        s_axis_tuser,
    input  wire                              s_axis_tlast,
    input  wire                              s_axis_tvalid,
    output reg                               s_axis_tready,

    // AXI4-Stream Master Interface (Output Data)
    output wire [C_M_AXIS_TDATA_WIDTH-1:0]   m_axis_tdata,
    output reg                               m_axis_tlast,
    output reg                               m_axis_tvalid,
    input  wire                              m_axis_tready,

    // Interrupt
    output wire                              irq_done
);

    wire clk   = s_axi_lite_aclk;
    wire rst_n = s_axi_lite_aresetn;

    // Internal core signals
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

    wire [31:0] perf_total, perf_sram_rd, perf_sram_wr;
    wire [31:0] perf_compute, perf_stall, perf_zero_skip;

    systolic_baseline_top #(
        .ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH), .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .SRAM_DEPTH(SRAM_DEPTH), .ADDR_WIDTH(ADDR_WIDTH),
        .CFG_ADDR_WIDTH(CFG_ADDR_WIDTH)
    ) u_baseline_core (
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
    reg aw_en;

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

    wire axi_wr_en = s_axi_lite_awready && s_axi_lite_awvalid &&
                     s_axi_lite_wready  && s_axi_lite_wvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            core_cfg_we    <= 1'b0;
            core_cfg_addr  <= 0;
            core_cfg_wdata <= 0;
        end else begin
            core_cfg_we <= 1'b0;
            if (axi_wr_en) begin
                core_cfg_we    <= 1'b1;
                core_cfg_addr  <= axi_awaddr[6:2];
                core_cfg_wdata <= s_axi_lite_wdata;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_lite_bvalid <= 1'b0;
            s_axi_lite_bresp  <= 2'b00;
        end else begin
            if (axi_wr_en && ~s_axi_lite_bvalid) begin
                s_axi_lite_bvalid <= 1'b1;
                s_axi_lite_bresp  <= 2'b00;
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

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_lite_rvalid <= 1'b0;
            s_axi_lite_rresp  <= 2'b00;
            s_axi_lite_rdata  <= 0;
        end else begin
            if (s_axi_lite_arready && s_axi_lite_arvalid && ~s_axi_lite_rvalid) begin
                s_axi_lite_rvalid <= 1'b1;
                s_axi_lite_rresp  <= 2'b00;

                case (axi_araddr[6:2])
                    5'd0:  s_axi_lite_rdata <= 32'd0;
                    5'd9:  s_axi_lite_rdata <= {29'd0, core_output_valid, core_busy, core_done};
                    5'd10: s_axi_lite_rdata <= {24'd0, core_output_count};
                    5'd11: s_axi_lite_rdata <= perf_total;
                    5'd12: s_axi_lite_rdata <= perf_sram_rd;
                    5'd13: s_axi_lite_rdata <= perf_sram_wr;
                    5'd14: s_axi_lite_rdata <= perf_compute;
                    5'd15: s_axi_lite_rdata <= perf_stall;
                    5'd16: s_axi_lite_rdata <= perf_zero_skip;
                    default: begin
                        core_cfg_raddr   <= axi_araddr[6:2];
                        s_axi_lite_rdata <= core_cfg_rdata;
                    end
                endcase
            end else if (s_axi_lite_rvalid && s_axi_lite_rready) begin
                s_axi_lite_rvalid <= 1'b0;
            end
        end
    end

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
            core_ext_weight_we <= 1'b0;
            core_ext_act_we    <= 1'b0;
            core_bias_we       <= 1'b0;
            s_axis_tready      <= ~core_busy;

            if (s_axis_tvalid && s_axis_tready) begin
                case (s_axis_tuser)
                    2'b00: begin
                        core_ext_waddr     <= stream_waddr;
                        core_ext_wdata     <= s_axis_tdata[ARRAY_SIZE*DATA_WIDTH-1:0];
                        core_ext_weight_we <= 1'b1;
                        stream_waddr       <= s_axis_tlast ? {ADDR_WIDTH{1'b0}} : stream_waddr + 1;
                    end
                    2'b01: begin
                        core_ext_waddr   <= stream_waddr;
                        core_ext_wdata   <= s_axis_tdata[ARRAY_SIZE*DATA_WIDTH-1:0];
                        core_ext_act_we  <= 1'b1;
                        stream_waddr     <= s_axis_tlast ? {ADDR_WIDTH{1'b0}} : stream_waddr + 1;
                    end
                    2'b10: begin
                        core_bias_waddr   <= stream_bias_waddr;
                        core_bias_wdata   <= s_axis_tdata[ARRAY_SIZE*ACC_WIDTH-1:0];
                        core_bias_we      <= 1'b1;
                        stream_bias_waddr <= s_axis_tlast ? {ADDR_WIDTH{1'b0}} : stream_bias_waddr + 1;
                    end
                    default: ;
                endcase

                if (s_axis_tlast) begin
                    stream_waddr      <= 0;
                    stream_bias_waddr <= 0;
                end
            end
        end
    end

    reg [ADDR_WIDTH-1:0] out_read_addr;
    reg [1:0]            out_state;
    localparam OUT_IDLE = 2'd0;
    localparam OUT_READ = 2'd1;
    localparam OUT_SEND = 2'd2;

    assign m_axis_tdata = core_out_rdata;

    always @(posedge clk) begin
        if (!rst_n) begin
            out_state       <= OUT_IDLE;
            out_read_addr   <= 0;
            core_out_raddr  <= 0;
            m_axis_tvalid   <= 1'b0;
            m_axis_tlast    <= 1'b0;
        end else begin
            case (out_state)
                OUT_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    if (core_done) begin
                        out_state      <= OUT_READ;
                        out_read_addr  <= 0;
                        core_out_raddr <= 0;
                    end
                end

                OUT_READ: begin
                    core_out_raddr <= out_read_addr;
                    out_state      <= OUT_SEND;
                end

                OUT_SEND: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= (out_read_addr == core_output_count - 1);

                    if (m_axis_tready) begin
                        if (out_read_addr >= core_output_count - 1) begin
                            out_state     <= OUT_IDLE;
                            m_axis_tvalid <= 1'b0;
                            m_axis_tlast  <= 1'b0;
                        end else begin
                            out_read_addr <= out_read_addr + 1;
                            out_state     <= OUT_READ;
                        end
                    end
                end

                default: out_state <= OUT_IDLE;
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
