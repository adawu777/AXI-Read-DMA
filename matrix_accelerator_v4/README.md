# Matrix Accelerator v4.0.0 — local release candidate

Fixed 4×4 INT8 A × B with signed 32-bit C results. This candidate reuses the existing Step 9H-C RTL without changes. Top module: `matrix_dma_compute_top`.

## Architecture

External AXI4 memory → upstream `axi_dma_rd` → 32-bit AXI-Stream → staging adapter → banked A/B SRAM → input skew and 4×4 systolic array → writeback controller → C SRAM. Jobs load A and B sequentially using two 16-byte descriptors, then compute. Read C through `c_rd_addr` / `c_rd_data`.

The staging adapter retains the verified DRAIN recovery fix: a failed DMA status may precede the last stream beat; the adapter consumes remaining data through TLAST before reporting the error. The existing upstream `axi_dma_rd` source and Alex Forencich copyright/MIT permission notice are retained verbatim.

## Source layout

- `rtl/`: 15 separate modules; compile this set alone.
- `tb/step9h_c_testbench.sv`: existing procedural stress testbench.
- `eda_playground/design.sv` and `testbench.sv`: verbatim combined baseline and Step 9H-C testbench. Compile this design instead of the separate RTL files to avoid duplicates.
- `docs/architecture/` and `docs/verification/`: copies of existing architecture, verification, limitation and recovery documents.
- `scripts/run_icarus.sh`: separate/combined source regression runner.

All three Step 9H testbenches are present. The corrected Step 9H-B candidate source uses registered RVALID and R payload, holds them during stalls, includes a procedural stability assertion, and checks B-DECERR descriptor, AR, status and B error coverage. All five error/reset recovery scenarios are present. These are source-inspection findings; historical EDA Playground PASS results remain distinct from local simulation. The repository-level Step 9H-B file is an older version; the corrected candidate file is the release source. Testbench contents were not modified during final preparation.

## EDA Playground and local simulation

Select Icarus Verilog, flags `-Wall -g2012`, testbench top `tb_step9h_c`. Paste only the two files from `eda_playground/`.

From this directory run:

```sh
./scripts/run_icarus.sh
./scripts/run_icarus.sh --combined
```

The default mode explicitly lists the 15 RTL files. The alternate mode checks the combined design using the same testbench. Outputs are temporary and removed when the script exits. No UVM or advanced SVA dependency is introduced.

**Local check, 2026-10-10:** neither `iverilog` nor `vvp` is installed/on PATH. No local compilation or regression PASS is claimed.

## Historical EDA Playground results

These are previously observed results supplied for the project, not new local runs:

| Regression | Historical result |
|---|---|
| Step 9H-B | Five functional tests passed, including Error Injection and Reset Recovery; Errors = 2; Recovery Jobs = 3 |
| Step 9H-C | Six randomized stress jobs passed; Descriptors = 12; AXI AR = 12; AXI R Beats = 48; AXI-Stream Beats = 48; TLAST = 12; DMA Status = 12; AR Stall Cycles = 43; R Idle Cycles = 188 |

Step 9H-C uses deterministic seed `C0FFEE21`. R idle cycles count active transactions without RVALID, not RVALID/RREADY stall coverage. Historical results do not establish exhaustive protocol coverage; full simulation logs are not included in this candidate.

## Known limitations

Fixed 4×4 INT8 configuration; AXI Read DMA only; no AXI Write DMA; output remains in C SRAM; no DMA/compute overlap; one job at a time. DRAIN has no timeout if TLAST never arrives. Reset and malformed-frame coverage remain limited. No synthesis, STA, FPGA/ASIC implementation signoff or production readiness is claimed.

See `RELEASE_CHECKLIST.md` for preparation gates and `docs/verification/Known_Limitations_Design_Review.md` for open risks. Existing repository-level AXI Read DMA v1.0 files remain available separately.
