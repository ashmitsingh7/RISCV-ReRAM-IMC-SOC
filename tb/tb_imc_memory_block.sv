// =============================================================================
// tb_imc_memory_block.sv
//
// WHAT THIS TESTS:
//   The imc_memory_block wrapper and everything inside it:
//     1. AXI write/read tasks (peripheral register access)
//     2. Weight programming (TRIG_PROG) and STATUS handshake
//     3. ReRAM reset (TRIG_RESET)
//     4. Direct CPU<->SRAM data port (SRAM_ADDR/SRAM_WDATA/SRAM_RDATA) —
//        a real AXI-reachable round trip, no simulation backdoor
//     5. Full TRIG_COMPUTE — all 16 rows, DMA load/compute/save cycle,
//        with matrix A loaded and results read back entirely over AXI
//     6. Correctness check against software reference
//     7. Saturation and signed-MAC checks, also loaded/read over AXI
//
// NOTE ON THE PREVIOUS VERSION OF THIS TESTBENCH:
//   The original version preloaded matrix A and read back results with a
//   simulation-only backdoor (`dut.u_sram.mem[...] = ...`), because
//   imc_sram had no CPU-reachable port at all. imc_peripheral now exposes
//   SRAM_ADDR/SRAM_WDATA/SRAM_RDATA registers (see imc_peripheral.sv), and
//   imc_memory_block.sv arbitrates them onto the SRAM bus against imc_dma.
//   This version exercises that real port instead, which is the same
//   sequence firmware running on the actual picorv32 core would use.
//
// TEST MATRIX:
//   We use a simple but non-trivial 16x16 weight matrix W and a 16x16
//   input matrix A, then verify output = A * W (saturated 32-bit).
//
//   W is the identity-like matrix: W[i][i] = (i+1), all others 0.
//   So output[j] = input[j] * (j+1)  for each row of A.
//
//   A row r: A[r][i] = r + i + 1  (small values, no saturation)
//
//   Expected output[r][j] = A[r][j] * (j+1) = (r + j + 1) * (j + 1)
//
// SRAM LAYOUT:
//   src_addr = 0  (word 0, matrix A starts at SRAM[0])
//     Row 0 occupies words  0..15
//     Row 1 occupies words 16..31
//     ...
//     Row r occupies words r*16 .. r*16+15
//
//   dst_addr = 256 (word 256, results start at SRAM[256])
//     Row 0 result at words 256..271
//     Row r result at words 256+r*16 .. 256+r*16+15
//
// =============================================================================

`timescale 1ns/1ps

module tb_imc_memory_block;

    // =========================================================================
    // Clock and reset
    // =========================================================================
    logic clk;
    logic reset;

    localparam CLK_PERIOD = 10; // 10ns = 100MHz
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // AXI interface and DUT instantiation
    // =========================================================================
    axi_interf imc_axi();

    imc_memory_block dut (
        .clk     (clk),
        .reset   (reset),
        .imc_axi (imc_axi)
    );

    // =========================================================================
    // Peripheral register offsets
    // =========================================================================
    localparam PROG_ROW     = 32'h00;
    localparam PROG_COL     = 32'h04;
    localparam PROG_WEIGHT  = 32'h08;
    localparam SRC_ADDR     = 32'h0C;
    localparam DST_ADDR     = 32'h10;
    localparam TRIG_PROG    = 32'h14;
    localparam TRIG_COMPUTE = 32'h18;
    localparam TRIG_RESET   = 32'h1C;
    localparam STATUS       = 32'h20;
    localparam CLEAR        = 32'h24;
    localparam SRAM_ADDR    = 32'h28;
    localparam SRAM_WDATA   = 32'h2C;
    localparam SRAM_RDATA   = 32'h30;

    // STATUS values
    localparam ST_IDLE  = 2'd0;
    localparam ST_BUSY  = 2'd1;
    localparam ST_DONE  = 2'd2;

    // SRAM layout
    localparam SRC_WORD_BASE = 15'h0000;  // matrix A at word 0
    localparam DST_WORD_BASE = 15'h0100;  // results at word 256

    // Timeout guard
    localparam MAX_CYCLES = 100000;

    // =========================================================================
    // AXI master tasks
    // =========================================================================

    // --- AXI Write ---
    // Drives AW and W simultaneously. The peripheral has awready and wready
    // both HIGH by default so both channels handshake in the same cycle.
    // We track each channel independently so this also handles the case
    // where one is accepted before the other.
    task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
        logic aw_done, w_done;
        aw_done = 0;
        w_done  = 0;

        @(posedge clk);
        imc_axi.awvalid <= 1'b1;
        imc_axi.awaddr  <= addr;
        imc_axi.awprot  <= 3'b000;
        imc_axi.wvalid  <= 1'b1;
        imc_axi.wdata   <= data;
        imc_axi.wstrb   <= 4'hF;
        imc_axi.bready  <= 1'b1;

        // Wait until both AW and W have been accepted
        while (!aw_done || !w_done) begin
            @(posedge clk);
            if (imc_axi.awvalid && imc_axi.awready) begin
                imc_axi.awvalid <= 1'b0;
                aw_done = 1;
            end
            if (imc_axi.wvalid && imc_axi.wready) begin
                imc_axi.wvalid <= 1'b0;
                w_done = 1;
            end
        end

        // Wait for B response
        while (!imc_axi.bvalid) @(posedge clk);
        imc_axi.bready <= 1'b0;
        @(posedge clk);
    endtask

    // --- AXI Read ---
    // Drives AR channel, waits for R response, returns rdata.
    task automatic axi_read(input logic [31:0] addr, output logic [31:0] data);
        @(posedge clk);
        imc_axi.arvalid <= 1'b1;
        imc_axi.araddr  <= addr;
        imc_axi.arprot  <= 3'b000;
        imc_axi.rready  <= 1'b1;

        // Wait for AR handshake
        @(posedge clk);
        while (!imc_axi.arready) @(posedge clk);
        imc_axi.arvalid <= 1'b0;

        // Wait for R response
        while (!imc_axi.rvalid) @(posedge clk);
        data = imc_axi.rdata;
        imc_axi.rready <= 1'b0;
        @(posedge clk);
    endtask

    // --- Poll STATUS until it equals expected value (with timeout) ---
    task automatic wait_status(input logic [1:0] expected);
        logic [31:0] rdata;
        int timeout = 0;
        do begin
            axi_read(STATUS, rdata);
            timeout++;
            if (timeout > MAX_CYCLES) begin
                $display("TIMEOUT waiting for STATUS=%0d (got %0d)", expected, rdata[1:0]);
                $finish;
            end
        end while (rdata[1:0] != expected);
    endtask

    // --- Write CLEAR to return peripheral to IDLE ---
    task automatic clear_status();
        axi_write(CLEAR, 32'h1);
    endtask

    // --- Program one ReRAM weight cell ---
    task automatic prog_weight(
        input logic [3:0]  row,
        input logic [3:0]  col,
        input logic signed [31:0] weight
    );
        axi_write(PROG_ROW,    {28'b0, row});
        axi_write(PROG_COL,    {28'b0, col});
        axi_write(PROG_WEIGHT, weight);
        axi_write(TRIG_PROG,   32'h1);
        wait_status(ST_DONE);
        clear_status();
    endtask

    // --- Write one word into SRAM via the real AXI-facing CPU data port ---
    task automatic sram_write(input logic [14:0] addr, input logic signed [31:0] data);
        axi_write(SRAM_ADDR,  {17'b0, addr});
        axi_write(SRAM_WDATA, data);
    endtask

    // --- Read one word from SRAM via the real AXI-facing CPU data port ---
    task automatic sram_read(input logic [14:0] addr, output logic signed [31:0] data);
        logic [31:0] rdata;
        axi_write(SRAM_ADDR, {17'b0, addr});
        axi_read(SRAM_RDATA, rdata);
        data = rdata;
    endtask

    // =========================================================================
    // Test data
    // =========================================================================

    // Weight matrix: W[i][i] = i+1, off-diagonal = 0
    // output[j] = sum_i(input[i] * W[i][j]) = input[j] * (j+1)
    logic signed [31:0] W [16][16];

    // Input matrix A: A[r][i] = r + i + 1
    logic signed [31:0] A [16][16];

    // Expected output: out[r][j] = A[r][j] * (j+1) = (r+j+1)*(j+1)
    logic signed [31:0] expected [16][16];

    // =========================================================================
    // Test counters
    // =========================================================================
    int pass_count;
    int fail_count;

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        // ── Init signals ──────────────────────────────────────────────────────
        clk             = 0;
        reset           = 1;
        pass_count      = 0;
        fail_count      = 0;

        imc_axi.awvalid = 0;
        imc_axi.awaddr  = 0;
        imc_axi.awprot  = 0;
        imc_axi.wvalid  = 0;
        imc_axi.wdata   = 0;
        imc_axi.wstrb   = 0;
        imc_axi.bready  = 0;
        imc_axi.arvalid = 0;
        imc_axi.araddr  = 0;
        imc_axi.arprot  = 0;
        imc_axi.rready  = 0;

        // ── Reset for 5 cycles ────────────────────────────────────────────────
        repeat(5) @(posedge clk);
        reset = 0;
        repeat(2) @(posedge clk);

        $display("");
        $display("=================================================");
        $display("  IMC Memory Block Testbench");
        $display("=================================================");

        // =====================================================================
        // TEST 1: STATUS reads IDLE after reset
        // =====================================================================
        $display("\n[TEST 1] STATUS = IDLE after reset");
        begin
            logic [31:0] rdata;
            axi_read(STATUS, rdata);
            if (rdata[1:0] == ST_IDLE) begin
                $display("  PASS: STATUS = IDLE (0x%0h)", rdata);
                pass_count++;
            end else begin
                $display("  FAIL: STATUS = 0x%0h, expected IDLE", rdata);
                fail_count++;
            end
        end

        // =====================================================================
        // TEST 2: TRIG_RESET clears weights and returns STATUS=DONE
        // =====================================================================
        $display("\n[TEST 2] TRIG_RESET -> STATUS=DONE -> CLEAR -> STATUS=IDLE");
        begin
            logic [31:0] rdata;
            axi_write(TRIG_RESET, 32'h1);
            wait_status(ST_DONE);
            $display("  PASS: STATUS=DONE after TRIG_RESET");
            pass_count++;
            clear_status();
            axi_read(STATUS, rdata);
            if (rdata[1:0] == ST_IDLE) begin
                $display("  PASS: STATUS=IDLE after CLEAR");
                pass_count++;
            end else begin
                $display("  FAIL: STATUS=0x%0h after CLEAR, expected IDLE", rdata);
                fail_count++;
            end
        end

        // =====================================================================
        // TEST 3: TRIG_PROG single cell and STATUS handshake
        // =====================================================================
        $display("\n[TEST 3] TRIG_PROG single cell W[0][0]=7");
        begin
            logic [31:0] rdata;
            axi_write(PROG_ROW,    32'h0);
            axi_write(PROG_COL,    32'h0);
            axi_write(PROG_WEIGHT, 32'h7);
            axi_write(TRIG_PROG,   32'h1);
            wait_status(ST_DONE);
            $display("  PASS: STATUS=DONE after TRIG_PROG");
            pass_count++;
            clear_status();
            axi_read(STATUS, rdata);
            if (rdata[1:0] == ST_IDLE) begin
                $display("  PASS: STATUS=IDLE after CLEAR");
                pass_count++;
            end else begin
                $display("  FAIL: STATUS=0x%0h after CLEAR, expected IDLE", rdata);
                fail_count++;
            end
        end

        // =====================================================================
        // TEST 4: Direct CPU<->SRAM data port round trip (no backdoor)
        // =====================================================================
        $display("\n[TEST 4] Direct SRAM_ADDR/SRAM_WDATA/SRAM_RDATA round trip");
        begin
            logic signed [31:0] got;
            sram_write(15'd42, 32'sd123456);
            sram_read(15'd42, got);
            if (got === 32'sd123456) begin
                $display("  PASS: wrote 123456 to SRAM[42] over AXI, read it back");
                pass_count++;
            end else begin
                $display("  FAIL: SRAM[42] read back %0d, expected 123456", got);
                fail_count++;
            end

            // A second, different address, to rule out an address being stuck
            sram_write(15'd100, -32'sd7);
            sram_read(15'd100, got);
            if (got === -32'sd7) begin
                $display("  PASS: wrote -7 to SRAM[100] over AXI, read it back");
                pass_count++;
            end else begin
                $display("  FAIL: SRAM[100] read back %0d, expected -7", got);
                fail_count++;
            end
        end

        // =====================================================================
        // TEST 5: Full MAC — program W, load SRAM over AXI, run TRIG_COMPUTE,
        //         read results back over AXI
        // =====================================================================
        $display("\n[TEST 5] Full 16x16 MAC operation (fully AXI-driven)");

        // ── Step 5a: Reset all weights first ─────────────────────────────────
        $display("  Step 5a: Reset weights");
        axi_write(TRIG_RESET, 32'h1);
        wait_status(ST_DONE);
        clear_status();

        // ── Step 5b: Build test matrices ─────────────────────────────────────
        $display("  Step 5b: Building test matrices");
        foreach (W[i,j]) W[i][j] = (i == j) ? (i + 1) : 0;
        foreach (A[r,i]) A[r][i] = r + i + 1;
        foreach (expected[r,j]) expected[r][j] = A[r][j] * (j + 1);

        // ── Step 5c: Program weight matrix into ReRAM ─────────────────────────
        $display("  Step 5c: Programming %0d weights into ReRAM", 16);
        for (int i = 0; i < 16; i++) begin
            // Only diagonal is non-zero for this test matrix
            prog_weight(i[3:0], i[3:0], W[i][i]);
        end
        $display("  Done programming weights");

        // ── Step 5d: Load matrix A into imc_sram over the real AXI SRAM port ──
        // Row r occupies words r*16 .. r*16+15
        $display("  Step 5d: Loading matrix A into imc_sram over AXI (SRAM_ADDR/SRAM_WDATA)");
        for (int r = 0; r < 16; r++) begin
            for (int i = 0; i < 16; i++) begin
                sram_write((r*16 + i), A[r][i]);
            end
        end
        $display("  Done loading SRAM");

        // ── Step 5e: Set SRC/DST addresses and fire TRIG_COMPUTE ─────────────
        $display("  Step 5e: Setting SRC_ADDR=%0d DST_ADDR=%0d, firing TRIG_COMPUTE",
                 SRC_WORD_BASE, DST_WORD_BASE);
        axi_write(SRC_ADDR,     {17'b0, SRC_WORD_BASE});
        axi_write(DST_ADDR,     {17'b0, DST_WORD_BASE});
        axi_write(TRIG_COMPUTE, 32'h1);

        // ── Step 5f: Poll STATUS=BUSY then STATUS=DONE ────────────────────────
        $display("  Step 5f: Waiting for STATUS=DONE ...");
        wait_status(ST_DONE);
        $display("  STATUS=DONE received");
        clear_status();

        // ── Step 5g: Read results back over AXI and check correctness ────────
        $display("  Step 5g: Reading back results over AXI (SRAM_ADDR/SRAM_RDATA)");
        begin
            automatic int local_pass = 0;
            automatic int local_fail = 0;
            logic signed [31:0] got;
            logic signed [31:0] exp;

            for (int r = 0; r < 16; r++) begin
                for (int j = 0; j < 16; j++) begin
                    sram_read((DST_WORD_BASE + r*16 + j), got);
                    exp = expected[r][j];
                    if (got === exp) begin
                        local_pass++;
                    end else begin
                        $display("  FAIL: out[%0d][%0d] = %0d, expected %0d",
                                 r, j, got, exp);
                        local_fail++;
                        fail_count++;
                    end
                end
            end
            pass_count += local_pass;
            if (local_fail == 0)
                $display("  PASS: All 256 output elements correct");
            else
                $display("  %0d/%0d elements correct", local_pass, 256);
        end

        // =====================================================================
        // TEST 6: Saturation — program a weight large enough to saturate
        // =====================================================================
        $display("\n[TEST 6] Saturation check");
        begin
            logic signed [31:0] got;

            // Reset everything
            axi_write(TRIG_RESET, 32'h1);
            wait_status(ST_DONE);
            clear_status();

            // W[0][0] = INT32_MAX so any positive input saturates
            prog_weight(4'd0, 4'd0, 32'h7fffffff);

            // Load row 0 of SRAM over AXI: input[0] = 2, rest 0
            // output[0] = 2 * INT32_MAX -> overflows -> clamps to INT32_MAX
            for (int i = 0; i < 16; i++)
                sram_write(i, (i == 0) ? 32'sd2 : 32'sd0);

            // Zero all other rows so DMA has valid data
            for (int r = 1; r < 16; r++)
                for (int i = 0; i < 16; i++)
                    sram_write((r*16 + i), 32'sd0);

            axi_write(SRC_ADDR,     32'd0);
            axi_write(DST_ADDR,     {17'b0, DST_WORD_BASE});
            axi_write(TRIG_COMPUTE, 32'h1);
            wait_status(ST_DONE);
            clear_status();

            sram_read(DST_WORD_BASE + 0, got);  // row 0, col 0
            if (got === 32'sh7fffffff) begin
                $display("  PASS: Saturation correct: out[0][0] = 0x%0h", got);
                pass_count++;
            end else begin
                $display("  FAIL: out[0][0] = 0x%0h, expected 0x7fffffff", got);
                fail_count++;
            end
        end

        // =====================================================================
        // TEST 7: Negative weights — verify signed MAC
        // =====================================================================
        $display("\n[TEST 7] Negative weight MAC");
        begin
            logic signed [31:0] got;

            axi_write(TRIG_RESET, 32'h1);
            wait_status(ST_DONE);
            clear_status();

            // W[0][0] = -4
            prog_weight(4'd0, 4'd0, -32'sd4);

            // input[0] = 3 -> output[0] = 3 * -4 = -12
            for (int i = 0; i < 16; i++)
                sram_write(i, (i == 0) ? 32'sd3 : 32'sd0);
            for (int r = 1; r < 16; r++)
                for (int i = 0; i < 16; i++)
                    sram_write((r*16 + i), 32'sd0);

            axi_write(SRC_ADDR,     32'd0);
            axi_write(DST_ADDR,     {17'b0, DST_WORD_BASE});
            axi_write(TRIG_COMPUTE, 32'h1);
            wait_status(ST_DONE);
            clear_status();

            sram_read(DST_WORD_BASE + 0, got);
            if (got === -32'sd12) begin
                $display("  PASS: Negative MAC correct: out[0][0] = %0d", got);
                pass_count++;
            end else begin
                $display("  FAIL: out[0][0] = %0d, expected -12", got);
                fail_count++;
            end
        end

        // =====================================================================
        // Results summary
        // =====================================================================
        $display("");
        $display("=================================================");
        $display("  Results: %0d passed, %0d failed",
                 pass_count, fail_count);
        $display("=================================================");
        $display("");

        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");

        $display("");
        $finish;
    end

    // =========================================================================
    // Watchdog — kill sim if it hangs
    // =========================================================================
    initial begin
        #(MAX_CYCLES * CLK_PERIOD);
        $display("WATCHDOG TIMEOUT — simulation hung");
        $finish;
    end

endmodule
