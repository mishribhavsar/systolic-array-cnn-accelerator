
# --- Clock Constraint ---
create_clock -period 10.000 -name sys_clk [get_ports clk]

# --- Pblock 1: Input SRAM + Systolic Array PEs + Skew Registers ---
create_pblock pblock_array_mem
add_cells_to_pblock [get_pblocks pblock_array_mem] \
    [get_cells -hierarchical -filter {NAME =~ *u_near_memory_input*}]
add_cells_to_pblock [get_pblocks pblock_array_mem] \
    [get_cells -hierarchical -filter {NAME =~ *u_systolic_array_core*}]
add_cells_to_pblock [get_pblocks pblock_array_mem] \
    [get_cells -hierarchical -filter {NAME =~ *gen_skew*}]
resize_pblock [get_pblocks pblock_array_mem] -add {
    SLICE_X0Y0:SLICE_X49Y49
    RAMB18_X0Y0:RAMB18_X0Y19
    RAMB36_X0Y0:RAMB36_X0Y9
    DSP48_X0Y0:DSP48_X0Y19
}

# --- Pblock 2: NMU Post-Processing Pipeline + Output BRAM + Bias BRAM ---
create_pblock pblock_nmu_output
add_cells_to_pblock [get_pblocks pblock_nmu_output] \
    [get_cells -hierarchical -filter {NAME =~ *u_near_memory_output*}]
add_cells_to_pblock [get_pblocks pblock_nmu_output] \
    [get_cells -hierarchical -filter {NAME =~ *u_output_collector*}]
add_cells_to_pblock [get_pblocks pblock_nmu_output] \
    [get_cells -hierarchical -filter {NAME =~ *bias_sram*}]
resize_pblock [get_pblocks pblock_nmu_output] -add {
    SLICE_X50Y0:SLICE_X65Y49
    RAMB18_X1Y0:RAMB18_X1Y19
    RAMB36_X1Y0:RAMB36_X1Y9
}

# --- I/O Constraints (minimal for wrapper) ---
set_property IOSTANDARD LVCMOS33 [get_ports -filter {DIRECTION == IN}]
set_property IOSTANDARD LVCMOS33 [get_ports -filter {DIRECTION == OUT}]
