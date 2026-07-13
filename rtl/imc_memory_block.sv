// =============================================================================
// imc_memory_block.sv
//
// WHAT THIS IS:
//   The top-level wrapper for the entire IMC subsystem. Fully self-contained.
//   Four submodules, all wired internally:
//     1. imc_peripheral  — AXI4-Lite slave, register file, FSM, CPU<->SRAM port
//     2. reram_array     — 16x16 weight crossbar, MAC engine
//     3. imc_dma         — burst engine, moves rows between SRAM and ReRAM
//     4. imc_sram        — 128KB dedicated SRAM for matrix A and results
//
// EXTERNAL INTERFACE (all that crosses the module boundary):
//     clk, reset    — clock and active-HIGH reset
//     imc_axi       — AXI4-Lite slave (RISC-V core talks here)
//
// INTERNAL DATA FLOW:
//
//   CPU ──AXI──► imc_peripheral
//                     │
//        ┌───────┬────┼─────────┬──────────┐
//        │       │    │         │          │
//     reram_mode │  trig_in  trig_out   cpu_sram_*
//     prog_*/    │  src/dst_addr  │      (SRAM_ADDR/
//     reram_done │    row         │       WDATA/RDATA
//        │       │     │          │       registers)
//        ▼       │     ▼          ▼          │
//    reram_array │  imc_dma ◄─────┘          │
//        │    │  │    │       │              │
//  output_vec │  │  dma_sram_*/we/rdata       │
//        │    │  │    │       │              │
//        │  input_vec │       ▼              ▼
//        │    │       │  ┌──────────────────────────┐
//        └────┘       └─►│  SRAM bus mux (2:1)       │
//                        │  selected by dma_active   │
//                        └────────────┬─────────────┘
//                                     ▼
//                                 imc_sram (128KB)
//
//   dma_active (from imc_peripheral) is HIGH only while the DMA is actively
//   loading/saving a row during TRIG_COMPUTE — so the CPU's direct SRAM
//   port (SRAM_ADDR/SRAM_WDATA/SRAM_RDATA) has the bus the rest of the time,
//   including immediately after reset and while PROG/RESET/DONE are held.
//   Firmware should still poll STATUS != busy before touching SRAM_ADDR/
//   SRAM_WDATA/SRAM_RDATA, since a stale access mid-mux-switch would just be
//   silently dropped rather than flagged as an error.
//
// RESET NOTE:
//   top.sv instantiates this block as:
//       imc_memory_block imc (.reset(!resetn), ...)
//   So reset here is active-HIGH, consistent with imc_peripheral and
//   reram_array (both use active-high rst). imc_sram and imc_dma also
//   use active-high rst/reset throughout.
//
// CHANGES FROM PREVIOUS imc_memory_block:
//   - All external DMA and SRAM ports removed (now internal wires)
//   - imc_dma and imc_sram instantiated here for the first time
//   - Bug fix: previous version used undeclared wire 'rst' in instantiations;
//     corrected to use the actual port name 'reset'
//   - NEW: added a 2:1 mux in front of imc_sram so imc_peripheral's direct
//     CPU data port (cpu_sram_addr/wdata/we/rdata) can share the SRAM with
//     imc_dma. This replaces the old simulation-only "backdoor force"
//     path (dut.u_sram.mem[...] = ...) with a real, synthesizable,
//     AXI-reachable way for firmware to load matrix A and read results.
//
// =============================================================================

module imc_memory_block (
    input  logic clk,
    input  logic reset,         // active-HIGH

    // ── AXI4-Lite slave — RISC-V core talks to peripheral through here ───────
    axi_interf imc_axi
);

    // =========================================================================
    // Internal wires
    // =========================================================================

    // ── peripheral ↔ reram_array ──────────────────────────────────────────────
    logic [1:0]         reram_mode;
    logic [3:0]         reram_prog_row;
    logic [3:0]         reram_prog_col;
    logic signed [31:0] reram_prog_weight;
    logic               reram_done;

    // ── reram_array ↔ imc_dma ─────────────────────────────────────────────────
    logic signed [31:0] reram_input_vec  [16];  // DMA → ReRAM
    logic signed [31:0] reram_output_vec [16];  // ReRAM → DMA

    // ── peripheral ↔ imc_dma ──────────────────────────────────────────────────
    logic        dma_trig_in;
    logic        dma_trig_out;
    logic [14:0] dma_src_addr;
    logic [14:0] dma_dst_addr;
    logic [3:0]  dma_row;
    logic        dma_done;

    // ── imc_dma ↔ SRAM mux ────────────────────────────────────────────────────
    logic [14:0]        dma_sram_addr;
    logic signed [31:0] dma_sram_wdata;
    logic               dma_sram_we;

    // ── imc_peripheral ↔ SRAM mux (direct CPU data port) ───────────────────────
    logic [14:0]        cpu_sram_addr;
    logic signed [31:0] cpu_sram_wdata;
    logic               cpu_sram_we;
    logic signed [31:0] cpu_sram_rdata;

    // ── arbitration ────────────────────────────────────────────────────────────
    logic                dma_active;   // HIGH while imc_dma owns the SRAM bus

    // ── SRAM mux ↔ imc_sram (single shared port) ────────────────────────────────
    logic [14:0]        sram_addr;
    logic signed [31:0] sram_wdata;
    logic               sram_we;
    logic signed [31:0] sram_rdata;

    // =========================================================================
    // imc_peripheral
    // =========================================================================
    imc_peripheral u_peripheral (
        .clk               (clk),
        .rst               (reset),         // active-HIGH

        // AXI4-Lite
        .s_axi_awaddr      (imc_axi.awaddr),
        .s_axi_awvalid     (imc_axi.awvalid),
        .s_axi_awready     (imc_axi.awready),
        .s_axi_wdata       (imc_axi.wdata),
        .s_axi_wstrb       (imc_axi.wstrb),
        .s_axi_wvalid      (imc_axi.wvalid),
        .s_axi_wready      (imc_axi.wready),
        .s_axi_bresp       (imc_axi.bresp),
        .s_axi_bvalid      (imc_axi.bvalid),
        .s_axi_bready      (imc_axi.bready),
        .s_axi_araddr      (imc_axi.araddr),
        .s_axi_arvalid     (imc_axi.arvalid),
        .s_axi_arready     (imc_axi.arready),
        .s_axi_rdata       (imc_axi.rdata),
        .s_axi_rresp       (imc_axi.rresp),
        .s_axi_rvalid      (imc_axi.rvalid),
        .s_axi_rready      (imc_axi.rready),

        // ReRAM control
        .reram_mode        (reram_mode),
        .reram_prog_row    (reram_prog_row),
        .reram_prog_col    (reram_prog_col),
        .reram_prog_weight (reram_prog_weight),
        .reram_done        (reram_done),

        // DMA handshake
        .dma_trig_in       (dma_trig_in),
        .dma_trig_out      (dma_trig_out),
        .dma_src_addr      (dma_src_addr),
        .dma_dst_addr      (dma_dst_addr),
        .dma_row           (dma_row),
        .dma_done          (dma_done),

        // direct CPU <-> SRAM data port
        .cpu_sram_addr     (cpu_sram_addr),
        .cpu_sram_wdata    (cpu_sram_wdata),
        .cpu_sram_we       (cpu_sram_we),
        .cpu_sram_rdata    (cpu_sram_rdata),

        // bus arbitration
        .dma_active        (dma_active)
    );

    // =========================================================================
    // reram_array
    // =========================================================================
    reram_array u_reram (
        .clk              (clk),
        .rst              (reset),          // active-HIGH
        .mode             (reram_mode),
        .prog_row         (reram_prog_row),
        .prog_col         (reram_prog_col),
        .prog_weight      (reram_prog_weight),
        .input_vec        (reram_input_vec),
        .output_vec       (reram_output_vec),
        .done             (reram_done)
    );

    // =========================================================================
    // imc_dma
    // =========================================================================
    imc_dma u_dma (
        .clk              (clk),
        .rst              (reset),          // active-HIGH

        // Handshake with peripheral
        .trig_in          (dma_trig_in),
        .trig_out         (dma_trig_out),
        .src_addr         (dma_src_addr),
        .dst_addr         (dma_dst_addr),
        .row              (dma_row),
        .dma_done         (dma_done),

        // ReRAM vectors
        .input_vec        (reram_input_vec),
        .output_vec       (reram_output_vec),

        // SRAM interface (goes through the mux below, not directly to imc_sram)
        .sram_addr        (dma_sram_addr),
        .sram_wdata       (dma_sram_wdata),
        .sram_we          (dma_sram_we),
        .sram_rdata       (sram_rdata)
    );

    // =========================================================================
    // SRAM bus mux — imc_dma vs. imc_peripheral's direct CPU data port
    //
    // imc_sram is single-port, so only one master can drive it per cycle.
    // dma_active (from imc_peripheral) is HIGH only during the handful of
    // cycles per row where the DMA is mid-transfer for TRIG_COMPUTE; the
    // CPU port gets the bus at all other times, including immediately after
    // reset, so firmware can preload matrix A before ever triggering a
    // compute pass.
    // =========================================================================
    assign sram_addr  = dma_active ? dma_sram_addr  : cpu_sram_addr;
    assign sram_wdata = dma_active ? dma_sram_wdata : cpu_sram_wdata;
    assign sram_we    = dma_active ? dma_sram_we    : cpu_sram_we;
    assign cpu_sram_rdata = sram_rdata; // same registered read imc_dma already relies on

    // =========================================================================
    // imc_sram
    // =========================================================================
    imc_sram u_sram (
        .clk              (clk),
        // no reset — SRAM contents are undefined at startup, firmware is
        // responsible for writing matrix A before triggering COMPUTE
        .addr             (sram_addr),
        .wdata            (sram_wdata),
        .we               (sram_we),
        .rdata            (sram_rdata)
    );

endmodule
