# =============================================================================
# run.do — QuestaSim simulation script for tb_imc_memory_block
#
# Run from the directory containing all 7 .sv files, or adjust paths below.
# Launch with:
#   vsim -do run.do
# Or from within Questa:
#   do run.do
# =============================================================================

# ── Cleanup ───────────────────────────────────────────────────────────────────
quit -sim
if {[file exists work]} { vdel -lib work -all }
vlib work

# ── Compile all sources ───────────────────────────────────────────────────────
vlog -sv axi_interf.sv
vlog -sv reram_array.sv
vlog -sv imc_sram.sv
vlog -sv imc_peripheral.sv
vlog -sv imc_dma.sv
vlog -sv imc_memory_block.sv
vlog -sv tb_imc_memory_block.sv

# ── Simulate ──────────────────────────────────────────────────────────────────
vsim -voptargs="+acc" work.tb_imc_memory_block

# ── Waveforms ─────────────────────────────────────────────────────────────────
add wave -divider "Clock / Reset"
add wave -radix binary      /tb_imc_memory_block/clk
add wave -radix binary      /tb_imc_memory_block/reset

add wave -divider "AXI Master (TB → DUT)"
add wave -radix hex         /tb_imc_memory_block/imc_axi/awaddr
add wave -radix binary      /tb_imc_memory_block/imc_axi/awvalid
add wave -radix binary      /tb_imc_memory_block/imc_axi/awready
add wave -radix hex         /tb_imc_memory_block/imc_axi/wdata
add wave -radix binary      /tb_imc_memory_block/imc_axi/wvalid
add wave -radix binary      /tb_imc_memory_block/imc_axi/wready
add wave -radix binary      /tb_imc_memory_block/imc_axi/bvalid
add wave -radix binary      /tb_imc_memory_block/imc_axi/bready
add wave -radix hex         /tb_imc_memory_block/imc_axi/araddr
add wave -radix binary      /tb_imc_memory_block/imc_axi/arvalid
add wave -radix binary      /tb_imc_memory_block/imc_axi/arready
add wave -radix hex         /tb_imc_memory_block/imc_axi/rdata
add wave -radix binary      /tb_imc_memory_block/imc_axi/rvalid
add wave -radix binary      /tb_imc_memory_block/imc_axi/rready

add wave -divider "Peripheral FSM"
add wave -radix symbolic    /tb_imc_memory_block/dut/u_peripheral/state
add wave -radix unsigned    /tb_imc_memory_block/dut/u_peripheral/status
add wave -radix unsigned    /tb_imc_memory_block/dut/u_peripheral/row_cnt

add wave -divider "ReRAM Control"
add wave -radix binary      /tb_imc_memory_block/dut/reram_mode
add wave -radix unsigned    /tb_imc_memory_block/dut/reram_prog_row
add wave -radix unsigned    /tb_imc_memory_block/dut/reram_prog_col
add wave -radix decimal     /tb_imc_memory_block/dut/reram_prog_weight
add wave -radix binary      /tb_imc_memory_block/dut/reram_done

add wave -divider "DMA Handshake"
add wave -radix binary      /tb_imc_memory_block/dut/dma_trig_in
add wave -radix binary      /tb_imc_memory_block/dut/dma_trig_out
add wave -radix unsigned    /tb_imc_memory_block/dut/dma_src_addr
add wave -radix unsigned    /tb_imc_memory_block/dut/dma_dst_addr
add wave -radix unsigned    /tb_imc_memory_block/dut/dma_row
add wave -radix binary      /tb_imc_memory_block/dut/dma_done

add wave -divider "DMA FSM"
add wave -radix symbolic    /tb_imc_memory_block/dut/u_dma/state
add wave -radix unsigned    /tb_imc_memory_block/dut/u_dma/word_cnt
add wave -radix unsigned    /tb_imc_memory_block/dut/u_dma/lat_row
add wave -radix binary      /tb_imc_memory_block/dut/u_dma/doing_save

add wave -divider "SRAM Interface"
add wave -radix unsigned    /tb_imc_memory_block/dut/sram_addr
add wave -radix decimal     /tb_imc_memory_block/dut/sram_wdata
add wave -radix binary      /tb_imc_memory_block/dut/sram_we
add wave -radix decimal     /tb_imc_memory_block/dut/sram_rdata

add wave -divider "ReRAM Vectors"
add wave -radix decimal     /tb_imc_memory_block/dut/reram_input_vec
add wave -radix decimal     /tb_imc_memory_block/dut/reram_output_vec

# ── Run ───────────────────────────────────────────────────────────────────────
run -all
