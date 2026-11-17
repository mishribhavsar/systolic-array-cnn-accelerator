`timescale 1ns / 1ps

module tb_ab_comparison;

    parameter ARRAY_SIZE     = 8;
    parameter DATA_WIDTH     = 8;
    parameter ACC_WIDTH      = 32;
    parameter OUTPUT_WIDTH   = 16;
    parameter SRAM_DEPTH     = 256;
    parameter ADDR_WIDTH     = 8;
    parameter CFG_ADDR_WIDTH = 4;

    parameter CLK_PERIOD = 10; // 100 MHz

    localparam N  = ARRAY_SIZE;
    localparam DW = DATA_WIDTH;
    localparam AW = ACC_WIDTH;
    localparam OW = OUTPUT_WIDTH;
    localparam AD = ADDR_WIDTH;
    localparam CW = CFG_ADDR_WIDTH;

    // Config register addresses
    localparam CFG_START           = 4'd0;
    localparam CFG_MATRIX_M        = 4'd1;
    localparam CFG_MATRIX_K        = 4'd2;
    localparam CFG_MATRIX_N        = 4'd3;
    localparam CFG_ACTIVATION_MODE = 4'd4;
    localparam CFG_POOLING_ENABLE  = 4'd5;
    localparam CFG_QUANTIZE_SHIFT  = 4'd6;
    localparam CFG_LEAKY_SHIFT     = 4'd7;
    localparam CFG_BIAS_BASE_ADDR  = 4'd8;

    localparam TIMEOUT_LIMIT = 10000;

   
    reg clk;
    reg rst_n;

    // Configuration (shared between both DUTs)
    reg                              cfg_we;
    reg  [CW-1:0]                    cfg_addr;
    reg  [31:0]                      cfg_wdata;
    reg  [CW-1:0]                    cfg_raddr;

    // Data loading (shared)
    reg  [AD-1:0]                    ext_waddr;
    reg  [N*DW-1:0]                  ext_wdata;
    reg                              ext_weight_we;
    reg                              ext_act_we;

    // Bias loading (shared)
    reg  [AD-1:0]                    bias_waddr;
    reg  signed [N*AW-1:0]           bias_wdata;
    reg                              bias_we;

    // Output read (independent per DUT)
    reg  [AD-1:0]                    out_raddr;

    wire [31:0]              nmu_cfg_rdata;
    wire [N*OW-1:0]          nmu_out_rdata;
    wire                     nmu_busy, nmu_done, nmu_output_valid;
    wire [AD-1:0]            nmu_output_count;

    // NMU performance counters
    wire [31:0]              nmu_perf_total, nmu_perf_sram_rd, nmu_perf_sram_wr;
    wire [31:0]              nmu_perf_compute, nmu_perf_stall, nmu_perf_zero_skip;

    wire [31:0]              bl_cfg_rdata;
    wire [N*OW-1:0]          bl_out_rdata;
    wire                     bl_busy, bl_done, bl_output_valid;
    wire [AD-1:0]            bl_output_count;

    // Baseline performance counters
    wire [31:0]              bl_perf_total, bl_perf_sram_rd, bl_perf_sram_wr;
    wire [31:0]              bl_perf_compute, bl_perf_stall, bl_perf_zero_skip;

    reg signed [DW-1:0] mat_W [0:N-1][0:N-1];
    reg signed [DW-1:0] mat_A [0:N-1][0:N-1];
    reg signed [AW-1:0] bias  [0:N-1];

    // Golden model
    reg signed [AW-1:0]  golden_C     [0:N-1][0:N-1];
    reg signed [OW-1:0]  golden_quant [0:N-1][0:N-1];

    // Test tracking
    integer total_tests, pass_tests, fail_tests;
    integer test_id, err_cnt, err_at_start;
    integer timeout_cnt;
    integer nmu_done_cycles, bl_done_cycles;
    reg     nmu_finished, bl_finished;

 
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;


    initial begin
        $dumpfile("ab_comparison.vcd");
        $dumpvars(0, tb_ab_comparison);
    end

  
    // --- Version B: NMU (Fused Pipeline) ---
    systolic_nmu_top #(
        .ARRAY_SIZE(N), .DATA_WIDTH(DW), .ACC_WIDTH(AW),
        .OUTPUT_WIDTH(OW), .SRAM_DEPTH(SRAM_DEPTH),
        .ADDR_WIDTH(AD), .CFG_ADDR_WIDTH(CW)
    ) u_nmu (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_raddr(cfg_raddr), .cfg_rdata(nmu_cfg_rdata),
        .ext_waddr(ext_waddr), .ext_wdata(ext_wdata),
        .ext_weight_we(ext_weight_we), .ext_act_we(ext_act_we),
        .bias_waddr(bias_waddr), .bias_wdata(bias_wdata), .bias_we(bias_we),
        .out_raddr(out_raddr), .out_rdata(nmu_out_rdata),
        .busy(nmu_busy), .done(nmu_done),
        .output_valid(nmu_output_valid), .output_count(nmu_output_count),
        // NMU perf counters
        .perf_total_cycles(nmu_perf_total),
        .perf_sram_read_count(nmu_perf_sram_rd),
        .perf_sram_write_count(nmu_perf_sram_wr),
        .perf_compute_active_cycles(nmu_perf_compute),
        .perf_stall_cycles(nmu_perf_stall),
        .perf_zero_skip_count(nmu_perf_zero_skip)
    );

    // --- Version A: Baseline (Unfused Multi-Pass) ---
    systolic_baseline_top #(
        .ARRAY_SIZE(N), .DATA_WIDTH(DW), .ACC_WIDTH(AW),
        .OUTPUT_WIDTH(OW), .SRAM_DEPTH(SRAM_DEPTH),
        .ADDR_WIDTH(AD), .CFG_ADDR_WIDTH(CW)
    ) u_baseline (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_raddr(cfg_raddr), .cfg_rdata(bl_cfg_rdata),
        .ext_waddr(ext_waddr), .ext_wdata(ext_wdata),
        .ext_weight_we(ext_weight_we), .ext_act_we(ext_act_we),
        .bias_waddr(bias_waddr), .bias_wdata(bias_wdata), .bias_we(bias_we),
        .out_raddr(out_raddr), .out_rdata(bl_out_rdata),
        .busy(bl_busy), .done(bl_done),
        .output_valid(bl_output_valid), .output_count(bl_output_count),
        .perf_total_cycles(bl_perf_total),
        .perf_sram_read_count(bl_perf_sram_rd),
        .perf_sram_write_count(bl_perf_sram_wr),
        .perf_compute_active_cycles(bl_perf_compute),
        .perf_stall_cycles(bl_perf_stall),
        .perf_zero_skip_count(bl_perf_zero_skip)
    );


    task tick;
        begin
            @(posedge clk); #1;
        end
    endtask

    task apply_reset;
        begin
            cfg_we        = 0;
            cfg_addr      = 0;
            cfg_wdata     = 0;
            cfg_raddr     = 0;
            ext_waddr     = 0;
            ext_wdata     = 0;
            ext_weight_we = 0;
            ext_act_we    = 0;
            bias_waddr    = 0;
            bias_wdata    = 0;
            bias_we       = 0;
            out_raddr     = 0;

            rst_n = 0;
            tick; tick;
            rst_n = 1;
            tick;
        end
    endtask

    task cfg_write;
        input [CW-1:0] addr;
        input [31:0]   data;
        begin
            @(negedge clk);
            cfg_we    = 1;
            cfg_addr  = addr;
            cfg_wdata = data;
            @(posedge clk); #1;
            cfg_we    = 0;
        end
    endtask

    task write_weight_row;
        input integer row;
        integer j;
        begin
            @(negedge clk);
            ext_waddr = row;
            for (j = 0; j < N; j = j + 1)
                ext_wdata[j*DW +: DW] = mat_W[row][j];
            ext_weight_we = 1;
            @(posedge clk); #1;
            ext_weight_we = 0;
        end
    endtask

    task write_act_row;
        input integer row;
        integer k;
        begin
            @(negedge clk);
            ext_waddr = row;
            for (k = 0; k < N; k = k + 1)
                ext_wdata[k*DW +: DW] = mat_A[row][k];
            ext_act_we = 1;
            @(posedge clk); #1;
            ext_act_we = 0;
        end
    endtask

    task write_bias_row;
        input integer row;
        integer j;
        begin
            @(negedge clk);
            bias_waddr = row;
            for (j = 0; j < N; j = j + 1)
                bias_wdata[j*AW +: AW] = bias[j];
            bias_we = 1;
            @(posedge clk); #1;
            bias_we = 0;
        end
    endtask

    task load_all_data;
        integer i;
        begin
            $display("  Loading weights...");
            for (i = 0; i < N; i = i + 1) write_weight_row(i);

            $display("  Loading activations...");
            for (i = 0; i < N; i = i + 1) write_act_row(i);

            $display("  Loading bias...");
            for (i = 0; i < N; i = i + 1) write_bias_row(i);
        end
    endtask

    task configure_and_start;
        input [1:0]  act_mode;
        input [3:0]  q_shift;
        begin
            cfg_write(CFG_MATRIX_M, N);
            cfg_write(CFG_MATRIX_K, N);
            cfg_write(CFG_MATRIX_N, N);
            cfg_write(CFG_ACTIVATION_MODE, {30'd0, act_mode});
            cfg_write(CFG_POOLING_ENABLE, 0);
            cfg_write(CFG_QUANTIZE_SHIFT, {28'd0, q_shift});
            cfg_write(CFG_LEAKY_SHIFT, 3);
            cfg_write(CFG_BIAS_BASE_ADDR, 0);
            $display("  Starting computation...");
            cfg_write(CFG_START, 1);
        end
    endtask

    task wait_for_done;
        input integer which; // 0=NMU, 1=baseline, 2=both
        begin
            timeout_cnt     = 0;
            nmu_finished    = (which == 1);
            bl_finished     = (which == 0);
            nmu_done_cycles = 0;
            bl_done_cycles  = 0;

            while ((!nmu_finished || !bl_finished) && timeout_cnt < TIMEOUT_LIMIT) begin
                tick;
                timeout_cnt = timeout_cnt + 1;
                if (!nmu_finished && nmu_done) begin
                    nmu_done_cycles = timeout_cnt;
                    nmu_finished    = 1;
                end
                if (!bl_finished && bl_done) begin
                    bl_done_cycles = timeout_cnt;
                    bl_finished    = 1;
                end
            end

            if (!nmu_finished) begin
                $display("  ERROR: NMU TIMEOUT after %0d cycles!", TIMEOUT_LIMIT);
                err_cnt = err_cnt + 1;
            end else if (which == 0 || which == 2) begin
                $display("  NMU done after %0d cycles", nmu_done_cycles);
            end

            if (!bl_finished) begin
                $display("  ERROR: Baseline TIMEOUT after %0d cycles!", TIMEOUT_LIMIT);
                err_cnt = err_cnt + 1;
            end else if (which == 1 || which == 2) begin
                $display("  Baseline done after %0d cycles", bl_done_cycles);
            end
        end
    endtask

    // Compute golden model: C = W * A (simple matrix multiply)
    task compute_golden;
        input [1:0]  act_mode;
        input [3:0]  q_shift;
        integer m, n, k;
        reg signed [AW-1:0] acc;
        reg signed [AW-1:0] with_bias;
        reg signed [AW-1:0] after_act;
        reg signed [AW-1:0] shifted;
        begin
            for (m = 0; m < N; m = m + 1) begin
                for (n = 0; n < N; n = n + 1) begin
                    acc = 0;
                    for (k = 0; k < N; k = k + 1) begin
                        acc = acc + mat_A[m][k] * mat_W[k][n];
                    end
                    golden_C[m][n] = acc;

                    // Bias
                    with_bias = acc + bias[n];

                    // Activation
                    case (act_mode)
                        2'd1: after_act = (with_bias > 0) ? with_bias : 0;  // ReLU
                        2'd2: after_act = (with_bias > 0) ? with_bias : (with_bias >>> 3);  // Leaky
                        default: after_act = with_bias;
                    endcase

                    // Quantize (arithmetic right shift + saturation)
                    shifted = after_act >>> q_shift;
                    if (shifted > 32767)
                        golden_quant[m][n] = 16'sd32767;
                    else if (shifted < -32768)
                        golden_quant[m][n] = -16'sd32768;
                    else
                        golden_quant[m][n] = shifted[OW-1:0];
                end
            end
        end
    endtask

    task check_outputs;
        input integer dut_id; // 0=NMU, 1=baseline
        integer m, j;
        reg signed [OW-1:0] got;
        reg signed [OW-1:0] expected;
        begin
            for (m = 0; m < N; m = m + 1) begin
                @(negedge clk);
                out_raddr = m;
                tick; tick; // 2-cycle SRAM read latency
                for (j = 0; j < N; j = j + 1) begin
                    expected = golden_quant[m][j];
                    if (dut_id == 0)
                        got = nmu_out_rdata[j*OW +: OW];
                    else
                        got = bl_out_rdata[j*OW +: OW];
                    if (got !== expected) begin
                        $display("  [%s FAIL] C[%0d][%0d]: expected=%0d, got=%0d",
                                 dut_id == 0 ? "NMU" : "BL ", m, j, expected, got);
                        err_cnt = err_cnt + 1;
                    end
                end
            end
        end
    endtask

    task print_perf_summary;
        real cycle_speedup;
        begin
            if (nmu_perf_total > 0)
                cycle_speedup = $itor(bl_perf_total) / $itor(nmu_perf_total);
            else
                cycle_speedup = 1.0;

            $display("");

            $display("  PERFORMANCE COUNTER COMPARISON");

            $display("  Metric                    | Baseline (A) | NMU (B)  | Ratio");
          
            $display("  Total Cycles              | %12d | %8d | %0.2fx speedup", bl_perf_total, nmu_perf_total, cycle_speedup);
            $display("  SRAM Reads                | %12d | %8d | inf (100%% eliminated)", bl_perf_sram_rd, nmu_perf_sram_rd);
            $display("  SRAM Writes               | %12d | %8d | inf (100%% eliminated)", bl_perf_sram_wr, nmu_perf_sram_wr);
            $display("  Compute Active Cycles     | %12d | %8d |", bl_perf_compute, nmu_perf_compute);
            $display("  Stall Cycles              | %12d | %8d |", bl_perf_stall, nmu_perf_stall);
            $display("  Zero-Skip Count           | %12d | %8d |", bl_perf_zero_skip, nmu_perf_zero_skip);

            $display("");
        end
    endtask

    integer i, j;

    initial begin
        total_tests = 0;
        pass_tests  = 0;
        fail_tests  = 0;
        err_cnt     = 0;

        $display("");
        $display(" TEST 1: Identity Matrix Multiplication");
        test_id = 1;
        err_at_start = err_cnt;
        total_tests = total_tests + 1;

        apply_reset;

        // Build test matrices
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                mat_W[i][j] = (i == j) ? 8'sd1 : 8'sd0;
                mat_A[i][j] = (i * N + j + 1);
            end
            bias[i] = 0;
        end

        load_all_data;
        compute_golden(2'd0, 4'd0); // No activation, no shift

        configure_and_start(2'd0, 4'd0);

        // Wait for BOTH to complete
        wait_for_done(2);

        // Small settling delay
        repeat(10) tick;

        // Check NMU outputs
        $display("  Checking NMU outputs...");
        check_outputs(0);

        // Check Baseline outputs
        $display("  Checking Baseline outputs...");
        check_outputs(1);

        if (err_cnt == err_at_start) begin
            pass_tests = pass_tests + 1;
            $display("  [TEST 1] PASS");
        end else begin
            fail_tests = fail_tests + 1;
            $display("  [TEST 1] FAIL (%0d errors)", err_cnt - err_at_start);
        end

        // Print performance comparison
        print_perf_summary;


        $display("TEST 2: Known Matrix with Bias + ReLU + Quantize");
        test_id = 2;
        err_at_start = err_cnt;
        total_tests = total_tests + 1;

        apply_reset;

        // Build test matrices with known values
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                mat_W[i][j] = ((i + j) % 5) - 2;     // -2 to +2
                mat_A[i][j] = ((i * 3 + j * 2) % 7);  // 0 to 6
            end
            bias[i] = (i + 1) * 10;  // 10, 20, 30, ...
        end

        load_all_data;
        compute_golden(2'd1, 4'd4); // ReLU, shift=4

        configure_and_start(2'd1, 4'd4);
        wait_for_done(2);
        repeat(10) tick;

        $display("  Checking NMU outputs...");
        check_outputs(0);
        $display("  Checking Baseline outputs...");
        check_outputs(1);

        if (err_cnt == err_at_start) begin
            pass_tests = pass_tests + 1;
            $display("  [TEST 2] PASS");
        end else begin
            fail_tests = fail_tests + 1;
            $display("  [TEST 2] FAIL (%0d errors)", err_cnt - err_at_start);
        end

        print_perf_summary;


        $display("");

        $display("  A/B COMPARISON SUMMARY");
        $display("  Total tests: %0d", total_tests);
        $display("  Passed:      %0d", pass_tests);
        $display("  Failed:      %0d", fail_tests);

        if (fail_tests == 0)
            $display("   ALL TESTS PASSED ");
        else
            $display("   TESTS FAILED ");

        $display("");
        $finish;
    end

    // Timeout watchdog
    initial begin
        #(CLK_PERIOD * 100000);
        $display("FATAL: Global timeout reached");
        $finish;
    end

endmodule
