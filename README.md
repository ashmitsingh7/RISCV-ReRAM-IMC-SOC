# ReRAM In-Memory-Compute Accelerator on a RISC-V SoC

A hackathon project pairing a **picorv32 RISC-V core** with a custom **ReRAM-based
in-memory-compute (IMC) accelerator** over AXI4-Lite, simulated in QuestaSim/ModelSim.

**What I built:** the ReRAM in-memory-compute subsystem — the crossbar array, its DMA
engine, its dedicated SRAM, the AXI4-Lite control peripheral, and the CPU-accessible
data path added during this cleanup pass. The RISC-V core (`picorv32.v`), UART, and
GPIO are unmodified third-party/open-source IP used as the surrounding SoC, not
something I designed.

> **Honesty-first status note:** this README states plainly what is done, what is
> untested, and what is still broken. See [Completeness & Known Issues](#completeness--known-issues)
> before you trust any of it in a demo.

---

## 1. What is in-memory compute, and what does this project actually do?

Normal matrix-multiply hardware shuttles data back and forth between memory and a
separate ALU/MAC array. In-memory compute instead performs the multiply-accumulate
**inside a memory array**: each cell stores a weight, and driving an input vector
across the array produces the dot-product as an analog/electrical side-effect of the
array itself. This project doesn't model the analog ReRAM physics — it's a
**digital, cycle-accurate behavioral model** of what that array's I/O and timing
would look like from the outside, which is the right level of abstraction for
proving out the surrounding SoC integration (control FSM, DMA, AXI, memory
mapping) in a hackathon timeframe.

Concretely: a 16×16 grid of signed 32-bit "weight" cells (`reram_array.sv`). Drive a
16-element input vector at it, and it produces a 16-element output vector where
`output = input_vector × W` — one full row of a 16×16 matrix multiply per pass,
computed combinationally inside the array.

---

## 2. System architecture

```
                              ┌─────────────────────────────────────────┐
                              │                top.sv                   │
                              │                                         │
   ┌──────────┐   native bus  │  ┌────────────┐   AXI4-Lite            │
   │ picorv32 │──────────────►│  │ picorv32_   │──────┐                │
   │  (core)  │               │  │ axi_adapter │      │                │
   └──────────┘               │  └────────────┘      ▼                │
                              │              ┌──────────────────┐      │
                              │              │  axi_interconnect │      │
                              │              │  (1 master, 4     │      │
                              │              │   slaves, addr    │      │
                              │              │   decode)         │      │
                              │              └─┬───┬────┬────┬──┘      │
                              │      0x00000    │   │    │    │ 0x30000 │
                              │      main mem◄──┘   │    │    └─►IMC    │
                              │   (simplemem)   UART │  GPIO   (this     │
                              │    0x18000◄─────┘    └─►0x20000 project) │
                              └─────────────────────────────────────────┘
```

Address map (from `axi_interconnect.sv`):

| Base addr  | Slave                                    |
|-----------:|-------------------------------------------|
| `0x00000`  | Main memory (`simplemem` + AXI adapter)    |
| `0x18000`  | UART (`simpleuart` + AXI controller)       |
| `0x20000`  | GPIO (`simplegpio`)                        |
| `0x30000`  | **IMC accelerator (`imc_memory_block`)**   |

### The IMC subsystem — `imc_memory_block.sv`

```
   CPU ──AXI──► imc_peripheral
                    │
       ┌───────┬────┼─────────┬──────────┐
       │       │    │         │          │
    reram_mode │  trig_in  trig_out   cpu_sram_*
    prog_*/    │  src/dst_addr  │      (SRAM_ADDR/
    reram_done │    row         │       WDATA/RDATA
       │       │     │          │       registers)
       ▼       │     ▼          ▼          │
   reram_array │  imc_dma ◄─────┘          │
       │    │  │    │       │              │
 output_vec │  │  dma_sram_*/we/rdata       │
       │    │  │    │       │              │
       │  input_vec │       ▼              ▼
       │    │       │  ┌──────────────────────────┐
       └────┘       └─►│  SRAM bus mux (2:1)       │
                       │  selected by dma_active   │
                       └────────────┬─────────────┘
                                    ▼
                                imc_sram (128KB)
```

Four submodules:

- **`imc_peripheral.sv`** — AXI4-Lite slave, register file, control FSM. This is
  where firmware talks to the accelerator.
- **`reram_array.sv`** — the 16×16 weight crossbar / MAC engine itself.
- **`imc_dma.sv`** — moves one 16-word row at a time between SRAM and the ReRAM
  array's input/output vectors during a compute pass.
- **`imc_sram.sv`** — 128KB dedicated SRAM holding matrix A and the results,
  separate from the CPU's main memory.

### Register map (`imc_peripheral.sv`, base `0x30000`)

| Offset | Name         | R/W | Purpose                                                  |
|-------:|--------------|:---:|-----------------------------------------------------------|
| 0x00   | `PROG_ROW`    | W  | Row index (0–15) for the next weight write                |
| 0x04   | `PROG_COL`    | W  | Column index (0–15) for the next weight write              |
| 0x08   | `PROG_WEIGHT` | W  | The weight value                                           |
| 0x0C   | `SRC_ADDR`    | W  | Word address in `imc_sram` where matrix A starts           |
| 0x10   | `DST_ADDR`    | W  | Word address in `imc_sram` where results should be written  |
| 0x14   | `TRIG_PROG`   | W  | Write anything → programs one ReRAM cell                    |
| 0x18   | `TRIG_COMPUTE`| W  | Write anything → runs the full 16-row matrix multiply        |
| 0x1C   | `TRIG_RESET`  | W  | Write anything → zeroes every ReRAM weight                  |
| 0x20   | `STATUS`      | R  | 0=idle, 1=busy, 2=done, 3=error                             |
| 0x24   | `CLEAR`       | W  | Write anything → acknowledges done/error, returns to idle    |
| 0x28   | `SRAM_ADDR`   | W  | **New.** Word address (0–32767) for direct SRAM access        |
| 0x2C   | `SRAM_WDATA`  | W  | **New.** Write this to store a word at `SRAM_ADDR`             |
| 0x30   | `SRAM_RDATA`  | R  | **New.** Reads back the word at `SRAM_ADDR`                    |

### Firmware flow for a full matrix multiply

```c
// 1. Load matrix A into imc_sram, one word at a time
for (i = 0; i < 256; i++) {
    IMC_SRAM_ADDR  = i;
    IMC_SRAM_WDATA = A[i];
}

// 2. Program the weight matrix into the ReRAM array
for (each weight w at (row, col)) {
    IMC_PROG_ROW = row; IMC_PROG_COL = col; IMC_PROG_WEIGHT = w;
    IMC_TRIG_PROG = 1;
    while (IMC_STATUS != DONE);
    IMC_CLEAR = 1;
}

// 3. Run the multiply
IMC_SRC_ADDR = 0;      // matrix A base
IMC_DST_ADDR = 256;    // result base
IMC_TRIG_COMPUTE = 1;
while (IMC_STATUS != DONE);
IMC_CLEAR = 1;

// 4. Read back the result
for (i = 0; i < 256; i++) {
    IMC_SRAM_ADDR = 256 + i;
    result[i] = IMC_SRAM_RDATA;
}
```

---

## 3. What changed in this cleanup pass

The single biggest gap found when reviewing the original hackathon code: **there was
no real way for the CPU to get data into or out of the accelerator.** `imc_sram` had
no AXI or CPU-facing port at all — the original testbench preloaded matrix A and
read back results with a **simulation-only backdoor** (`dut.u_sram.mem[...] = ...`,
a hierarchical force that only works inside a testbench, never on real hardware).
That meant the ReRAM MAC engine itself was solid, but the SoC integration around it
couldn't actually be used by firmware.

### Fix: a direct CPU↔SRAM data port

- **`imc_peripheral.sv`** gained three new registers — `SRAM_ADDR` (0x28),
  `SRAM_WDATA` (0x2C, write-triggered), `SRAM_RDATA` (0x30, read) — plus a new
  `dma_active` output that tells `imc_memory_block` whether the DMA is mid-transfer.
- **`imc_memory_block.sv`** gained a 2:1 mux in front of `imc_sram`, arbitrated by
  `dma_active`: the DMA owns the SRAM bus only during the handful of cycles per row
  where it's actively loading/saving during `TRIG_COMPUTE`; the CPU port has the bus
  the rest of the time, including immediately after reset — so firmware can preload
  matrix A before ever triggering a compute pass, and read results back afterward.
- **`imc_memory_block.sv`** also had a latent bug fixed in passing: the previous
  version referenced an undeclared signal `rst` in its submodule instantiations
  instead of the actual port name `reset`.
- **`tb_imc_memory_block.sv`** was rewritten to load matrix A and read back results
  through the new `SRAM_ADDR`/`SRAM_WDATA`/`SRAM_RDATA` registers over real AXI
  transactions, instead of the backdoor force — i.e. it now exercises the same
  sequence real firmware would use.

Everything else (`reram_array.sv`, `imc_dma.sv`, `imc_sram.sv`, `axi_interconnect.sv`,
`axi_interf.sv`, `top.sv`, `picorv32.v`, UART, GPIO) is **unchanged** from the
uploaded originals.

---

## 4. Completeness & Known Issues

**Last verification attempt: 2026-07-13** (from git log)

### Solid
- **`reram_array.sv`** — the MAC engine itself: clean, self-contained, no issues found.
- **`imc_dma.sv`, `imc_sram.sv`** — straightforward, no issues found.
- **`imc_peripheral.sv` / `imc_memory_block.sv`** — now has a real, arbitrated
  CPU↔SRAM data path (see above), closing the biggest functional gap.
- **`axi_interconnect.sv`, `axi_interf.sv`, `simplegpio.sv`** — clean AXI4-Lite,
  no issues found.

### Verification status — please read this before trusting a demo
This project's own `.do` scripts (`run_imc_tb.do`) target **QuestaSim/ModelSim**,
which isn't available in the sandbox this cleanup was done in. Two open-source
alternatives were used instead, with mixed results:

- **Verilator (`--lint-only`)** — the modified RTL elaborates cleanly: no port
  mismatches, no combinational loops, no unintentional multiple-driver conflicts.
  This gives real confidence the new mux/register wiring is structurally correct.
- **Verilator (`--binary`, full behavioral sim)** — compiles and runs, but exposed
  a **pre-existing race condition** in `tb_imc_memory_block.sv`'s AXI read task: it
  waits for `arready` to *reopen* as a proxy for "the whole read transaction
  completed," which is timing-sensitive between simulators and, under Verilator,
  causes the read task to miss the single-cycle `rvalid` pulse and hang. Manual
  signal tracing confirmed the underlying RTL handshake itself (`arvalid`/`arready`/
  `rvalid`/`rdata`) behaves correctly cycle-by-cycle — this is a testbench
  synchronization issue, not an RTL bug — but a fully race-free version of the
  testbench's AXI tasks was still being worked through when this package was cut.
- **Icarus Verilog** — does not support the generic `interface`-typed ports
  (`axi_interf imc_axi`) this design uses throughout, so it can't compile this
  codebase at all without restructuring every AXI-facing module's port list.

**Bottom line: the new SRAM_ADDR/WDATA/RDATA register logic and the SRAM bus mux
have been read carefully, elaborate cleanly, and were confirmed correct via direct
signal-level tracing of the AXI handshake — but a clean, complete, race-free
simulation run to a final PASS/FAIL count was not achieved in this environment.**
Treat the RTL changes as "should work, reviewed line-by-line, structurally
verified" rather than "simulated end-to-end and passing." **Run `sim/run_imc_tb.do`
in QuestaSim** (the tool this project was built for) to get an authoritative
pass/fail result — that's the next step, not this cleanup pass.

### Known gaps, not fixed here (out of scope — IMC-only cleanup)
- **`simplemem_axi_adapter.sv`** likely has a real bug unrelated to the IMC block:
  `assign mem_wready = mem_ready;` references an undeclared signal (should be
  `mem_axi.wready`), so the AXI write-data channel to main memory is probably never
  driven. This affects CPU writes to main RAM, not the IMC accelerator (which has
  its own independent, self-contained AXI slave in `imc_peripheral.sv`) — left
  alone since the ask for this pass was "make the in-memory-compute part as
  complete as possible."
- **No full-SoC testbench.** Only the IMC block has a dedicated testbench here;
  nothing in this repo exercises `top.sv` (CPU + interconnect + all four
  peripherals) end-to-end.
- **No firmware.** `top.sv` expects `../firmware/hex/smoke_test.hex`, which isn't
  part of this repo.
- **Minor:** `axi_interf.rresp` is declared 32 bits wide rather than the standard
  AXI4-Lite 2 bits. Harmless (only `[1:0]` is ever used) but worth tidying for spec
  cleanliness.
- **Firmware-side care needed:** the new `SRAM_ADDR`/`SRAM_WDATA`/`SRAM_RDATA`
  registers are only safe to use while `STATUS` is idle/done, never mid-compute —
  the hardware silently drops the access rather than flagging an error if firmware
  gets this wrong, so any driver code built on top of this should always poll
  `STATUS` first.

---

## 5. Repo layout

```
rtl/    — all synthesizable SystemVerilog/Verilog sources
tb/     — testbench for the IMC block
sim/    — QuestaSim/ModelSim project files and run scripts
```

To simulate (QuestaSim/ModelSim):
```
cd sim
vsim -do run_imc_tb.do
```

---

## 6. Credit

- `picorv32.v`, `simpleuart.v` — [picorv32](https://github.com/YosysHQ/picorv32) by
  Clifford Wolf, used unmodified as the RISC-V core and UART.
- Everything under `imc_*`, `reram_array.sv`, `axi_interconnect.sv`, `axi_interf.sv`,
  `simplegpio.sv`, `simplemem*.sv`, `simpleuart_controller.sv`, `top.sv` — original
  hackathon work (ReRAM in-memory-compute accelerator + SoC integration).
