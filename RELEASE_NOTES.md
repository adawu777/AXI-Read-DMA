# AXI Read DMA v1.0

Initial release of a reusable SystemVerilog AXI4 Read DMA for aligned transfers from external AXI memory into on-chip SRAM.

## Implemented features

- AXI4 read master with INCR bursts and a maximum of 256 beats per burst.
- Automatic multi-burst transfers and 4KB boundary splitting.
- ARREADY backpressure handling and RVALID stall handling.
- Sequential SRAM destination writes with one outstanding read burst.
- Sticky RRESP and RLAST error detection, including early and missing RLAST.
- Non-OKAY responses suppress the affected SRAM write while preserving the beat's destination position.
- Programmed beat counts control completion; done is a one-cycle pulse.

## Verification

The self-checking directed testbench passed **13 / 13 functional tests** under **Icarus Verilog 12.0**, using **SystemVerilog 2012**: single-beat and four-beat transfers, RVALID stalls, ARREADY backpressure, a 256-beat burst, a 257-beat two-burst transfer, 4KB splitting, combined 4KB/maximum-burst splitting, SLVERR, DECERR, early RLAST, missing RLAST, and sticky-error clearing on a new command.

The regression ended with **ALL TESTS PASSED**. The DMA RTL did not require modification for the final passing regression. Icarus testbench compatibility fixes preserved strict unknown-value checks; a diagnostic X injection confirmed that the corrected checker still detects unknowns.

The SVA checker is implemented for protocol, command legality, data-path, completion, and error behavior, but it was not executed in the current simulator. No SVA PASS result or assertion coverage is claimed.

## v1.0 limitations

- Read DMA only; aligned, nonzero, whole-beat transfers only.
- INCR only; no FIXED/WRAP bursts or Write DMA.
- One outstanding burst; no multiple IDs or out-of-order responses.
- No descriptor queue, scatter-gather, or 2D stride.
- No SRAM backpressure, retries, or hardware response timeout.
- Functional verification covers AXI_ADDR_W=32, AXI_DATA_W=32, SRAM_ADDR_W=16; no synthesis, timing, formal, or hardware result is claimed.

Remaining Icarus compile diagnostics concern missing explicit RTL time units and constant-select sensitivity handling in always_comb. They remain present in the passing regression.

## Future directions

Write DMA, multiple outstanding reads, FIFO/backpressure support, a descriptor engine, scatter-gather, and integration into the 4x4 INT8 Matrix Accelerator.
