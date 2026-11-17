## ==============================================================================
## Timing & Pin Constraints for Systolic Array with NMU
## Target FPGA: Zynq-7000 XC7Z020 (xc7z020clg400-1)
## Top module : systolic_nmu_top_wrapper (pin locations not assigned)
## ==============================================================================


## 1. Primary Clock Definition (100 MHz -> 10.0 ns period)
create_clock -period 10.000 -name clk -waveform {0.000 5.000} [get_ports clk]

## 2. Clock Uncertainty (accounts for PLL/MMCM jitter and power noise)
set_clock_uncertainty 0.200 [get_clocks clk]

## 3. Asynchronous Reset
## Reset is an asynchronous signal deasserted synchronously; false-path it for static timing
set_false_path -from [get_ports rst_n]

## 4. Input Delay Constraints (excluding clock port)
## Applied to synchronous serial shift interface inputs
set_input_delay -clock [get_clocks clk] -max 1.500 [get_ports {serial_in serial_in_valid serial_out_load}]
set_input_delay -clock [get_clocks clk] -min 0.500 [get_ports {serial_in serial_in_valid serial_out_load}]

## 5. Output Delay Constraints
## Serial shift output: constrained for high-speed shift register readback
set_output_delay -clock [get_clocks clk] -max 1.500 [get_ports serial_out]
set_output_delay -clock [get_clocks clk] -min 0.500 [get_ports serial_out]

## 6. Quasi-Static Status Outputs
## done, busy, output_valid, output_count stay asserted across multiple clock cycles.
## Set false path or multicycle path to avoid false routing violations on test/indicator pins.
set_false_path -to [get_ports {busy done output_valid output_count[*]}]

## 7. Pack I/O Registers into IOB where possible for minimum pin-to-pin delay
set_property IOB TRUE [get_ports serial_out]
