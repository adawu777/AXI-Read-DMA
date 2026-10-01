# AXI Read DMA v1.0

A reusable SystemVerilog AXI4 read DMA that transfers aligned, full-word data from external AXI memory into on-chip SRAM. The design separates transfer control from combinational burst planning and includes a self-checking directed regression suitable for RTL and ASIC verification portfolios, including accelerator memory-movement studies.

**Functional verification:** 13 / 13 directed tests passed using **Icarus Verilog 12.0**, **SystemVerilog 2012**. The final passing regression required testbench compatibility fixes; neither DMA RTL module required modification.

## 1. Project Overview

The command interface supplies an AXI source byte address, an SRAM destination word address, and a transfer length in bytes. The DMA issues one AXI read burst at a time, writes successful read responses to SRAM, and continues until the programmed length is consumed.

The implemented AXI interface contains the AR and R signals listed in the RTL. Integration into a wider AXI interface requires the surrounding system to provide any additional signals it needs; this module has no AXI write channel or transaction-ID interface.

## 2. Features

- AXI4 read master with INCR bursts and aligned transfers.
- Maximum 256 beats per burst.
- Automatic multi-burst transfers and 4KB boundary splitting.
- ARREADY backpressure handling with stable registered AR payload.
- RVALID stall handling; progress occurs only on accepted read beats.
- Detection of non-OKAY RRESP, early RLAST, and missing RLAST.
- Sequential, full-word SRAM writes with positional mapping across error beats.
- Sticky error status, cleared by reset or acceptance of a new command.
- Single outstanding read burst.
- One-cycle completion pulse.

## 3. Architecture

```text
DMA Command Interface
        |
        v
+--------------------------+
|       axi_read_dma       |
|                          |
|  Command Registers       |
|  Transfer Progress       |
|  FSM                     |
|  Burst Registers         |
|  R Beat Counter          |
|  Error Handling          |
|           |              |
|           v              |
|  Burst Manager           |
+------+--------------+----+
       |              |
       v              v
 AXI4 Read         SRAM Write
 Master            Interface
```

| Source | Responsibility |
|---|---|
| `rtl/axi_read_dma.sv` | Command capture, FSM, transfer progress, registered AR payload, read-beat counting, SRAM pointer and data path, completion, and sticky error handling. |
| `rtl/axi_read_dma_burst_manager.sv` | Combinational calculation of the next burst address, length, byte count, and beat count from the current source address and remaining bytes. |

The main DMA instantiates the burst manager. Its FSM is implemented directly in `axi_read_dma.sv`; the separate `rtl/axi_read_dma_fsm.sv` file is not a dependency of this top-level implementation.

### Configuration and interfaces

The verified configuration is:

```systemverilog
AXI_ADDR_W  = 32
AXI_DATA_W  = 32
SRAM_ADDR_W = 16
```

This provides four bytes per beat, `ARSIZE=2`, and a maximum burst size of 1024 bytes. The parameters remain configurable in the source; the reported regression covers the configuration above.

| Interface | Signals and behavior |
|---|---|
| Clock/reset | `clk`; asynchronous active-low `rst_n`. |
| Command | `cmd_valid`, `cmd_ready`, `cmd_axi_addr`, `cmd_sram_addr`, `cmd_len_bytes`. Source addresses and lengths are in bytes; SRAM addresses are word indices. |
| Status | `busy`, `done`, `error`. Busy remains high through the completion cycle. |
| AXI address | `m_axi_araddr`, `m_axi_arlen`, `m_axi_arsize`, `m_axi_arburst`, `m_axi_arvalid`, `m_axi_arready`. |
| AXI read data | `m_axi_rdata`, `m_axi_rresp`, `m_axi_rlast`, `m_axi_rvalid`, `m_axi_rready`. |
| SRAM write | `sram_we`, `sram_waddr`, `sram_wdata`; no write backpressure or byte enables. |

## 4. Burst Calculation

For a supported command:

```text
BEAT_BYTES      = AXI_DATA_W / 8
MAX_BURST_BYTES = 256 * BEAT_BYTES
bytes_to_4KB    = 4096 - current_axi_addr[11:0]

burst_bytes = min(bytes_remaining,
                  MAX_BURST_BYTES,
                  bytes_to_4KB)

burst_beats = burst_bytes / BEAT_BYTES
ARLEN       = burst_beats - 1
```

AXI encodes burst length as the number of beats minus one: `ARLEN=0` means one beat, and `ARLEN=255` means 256 beats. The RTL uses a right shift for byte-to-beat conversion, requiring a power-of-two beat size and aligned, whole-beat lengths.

## 5. 4KB Boundary Handling

An AXI burst must not cross a 4KB boundary. The burst manager limits the next burst to the bytes available before that boundary, then resumes at the next address.

For `AXI_DATA_W=32`, source address `0x0F00`, and length **3000 bytes**:

| Burst | ARADDR | Beats | ARLEN | Bytes |
|---|---|---:|---:|---:|
| 1 | `0x0F00` | 64 | 63 | 256 |
| 2 | `0x1000` | 256 | 255 | 1024 |
| 3 | `0x1400` | 256 | 255 | 1024 |
| 4 | `0x1800` | 174 | 173 | 696 |

Total: **64 + 256 + 256 + 174 = 750 beats = 3000 bytes**. A burst may end exactly at a 4KB boundary.

## 6. FSM

```text
IDLE
  |
  | command accepted
  v
PREPARE_BURST
  |
  v
SEND_AR
  |
  | AR handshake
  v
RECV_R
  |
  +-- more data --> PREPARE_BURST
  |
  +-- final -----> COMPLETE
                     |
                     v
                    IDLE
```

- **IDLE:** `cmd_ready=1`, `busy=0`; accept and capture a command.
- **PREPARE_BURST:** capture the combinational burst-manager outputs into burst registers. This gives command/progress registers time to update before the next burst is registered.
- **SEND_AR:** present the registered AR payload and hold it stable until ARREADY accepts it.
- **RECV_R:** accept read beats, advance the destination pointer, and track programmed burst progress.
- **COMPLETE:** assert `done` for one cycle while `busy` remains high, then return to IDLE.

Registering the AR payload before SEND_AR isolates the address channel from changing transfer-progress calculations and preserves its payload under backpressure.

## 7. AXI Handshakes

```systemverilog
cmd_fire = cmd_valid && cmd_ready;
ar_fire  = m_axi_arvalid && m_axi_arready;
r_fire   = m_axi_rvalid && m_axi_rready;
```

Commands are accepted only in IDLE. SEND_AR waits for a real AR handshake. RECV_R advances its beat counter and SRAM destination pointer only on a real R handshake; idle RVALID cycles do not create writes or progress.

The next burst is issued only after the programmed number of beats in the current burst has been accepted.

## 8. RLAST Handling

The programmed beat count determines expected burst completion:

```systemverilog
expected_last = (beats_received == burst_beats_reg - 1);
burst_done    = r_fire && expected_last;
```

For each accepted beat, RLAST is compared with `expected_last`. Early RLAST and missing RLAST set the sticky error flag. RLAST is not the sole source of completion: an early assertion does not shorten the programmed burst, and a missing final RLAST does not require a fifth beat for a four-beat burst.

This recovery policy still requires all programmed beats to arrive. The DUT has no hardware timeout if the external slave stops responding.

## 9. RRESP / Error Handling

Every accepted response other than OKAY (`2'b00`), including EXOKAY, sets sticky `error`. For such a beat, the DMA suppresses the SRAM write but still increments its SRAM destination pointer and accepted-beat count.

This preserves positional mapping:

| Beat | Response | SRAM result |
|---|---|---|
| 0 | OKAY | Write destination + 0 |
| 1 | OKAY | Write destination + 1 |
| 2 | SLVERR | Leave destination + 2 unchanged |
| 3 | OKAY | Write destination + 3 |

Later words are not shifted into the skipped location. Errors do not abort the programmed transfer or cause retries. `done` indicates completion of the programmed beat count; the consumer must also examine `error` to determine whether the transfer was successful.

Error remains asserted through completion and idle until reset or acceptance of a new command clears it.

## 10. Verification

`tb/tb_axi_read_dma.sv` is a directed, self-checking functional testbench without UVM. It uses a 10 ns clock, falling-edge AXI slave stimulus, a full SRAM memory model, handshake counters, sequential-address checks, strict X/Z and data checks, and timeout protection. It checks busy behavior and exactly one one-cycle done pulse per command.

The final functional regression passed **13 / 13** tests:

| # | Test | Main checks |
|---:|---|---|
| 1 | Single-beat transfer | One beat to SRAM `0x0010`, data `0x12345678`, correct AR fields. |
| 2 | Four-beat transfer | Four ordered writes starting at SRAM `0x0020`. |
| 3 | RVALID stalls | Gaps of 2, 1, and 3 idle cycles; no extra reads or writes. |
| 4 | ARREADY backpressure | Five stalled cycles; ARVALID and payload remain stable. |
| 5 | Maximum 256-beat burst | `ARLEN=255`; all 256 data words checked. |
| 6 | 257-beat / two-burst transfer | 256 + 1 beats; completion only after burst two. |
| 7 | 4KB boundary split | Two 64-beat bursts from `0x0F00` and `0x1000`. |
| 8 | Combined 4KB + maximum-burst split | Exact 64/256/256/174 sequence; all 750 words checked. |
| 9 | RRESP SLVERR | Error asserted, bad beat unwritten, later word retains its position. |
| 10 | RRESP DECERR | Error sticky, write suppressed, pointer advances. |
| 11 | Early RLAST | Error detected; all programmed beats still accepted. |
| 12 | Missing RLAST | Error detected; completion by programmed beat count. |
| 13 | Sticky error clear on a new command | Error clears on acceptance and successful transfer completes. |

### Run the functional regression

Install Icarus Verilog 12.0 and run from the repository root:

```bash
mkdir -p build
iverilog -Wall -g2012 -s tb_axi_read_dma \
  -o build/tb_axi_read_dma.vvp \
  rtl/axi_read_dma.sv \
  rtl/axi_read_dma_burst_manager.sv \
  tb/tb_axi_read_dma.sv
vvp build/tb_axi_read_dma.vvp
```

The simulation prints a PASS entry for every test and ends with:

```text
==================================================
AXI READ DMA v1.0 DIRECTED REGRESSION
==================================================
PASS: Single-beat transfer
PASS: Four-beat transfer
PASS: RVALID stall test
PASS: ARREADY backpressure test
PASS: Maximum 256-beat burst
PASS: 257-beat two-burst transfer
PASS: 4KB boundary split
PASS: Combined 4KB and 256-beat splitting
PASS: RRESP SLVERR handling
PASS: RRESP DECERR handling
PASS: Early RLAST detection
PASS: Missing RLAST detection
PASS: Sticky error clear on new command
==================================================
ALL TESTS PASSED
==================================================
```

## 11. Icarus Debugging Note

The original testbench reported X/Z on the first AR transaction. Cycle tracing showed correct DUT behavior:

```text
95 ns  : command accepted
105 ns : PREPARE_BURST
115 ns : AR handshake

ARADDR  = 0x1000
ARLEN   = 0
ARSIZE  = 2
ARBURST = INCR
```

The root cause was an Icarus evaluation issue involving `$isunknown()` directly on a concatenation, rather than an RTL bug. The testbench now materializes the fields into a packed sample before calling `$isunknown()`. A diagnostic unknown-value injection confirmed that the corrected checker still rejects X values. Flag-controlled polling loops also avoid Icarus's unsupported `break` statements.

Icarus 12.0 reports two classes of compile diagnostics in this flow:

- The RTL modules have no explicit time unit/time precision.
- The burst manager's `always_comb` constant selects cause Icarus to include all bits in sensitivity handling.

These diagnostics remained in the passing regression. Neither required a DMA architecture change.

## 12. SystemVerilog Assertions

`tb/axi_read_dma_sva.sv` contains parameterized assertions for AXI protocol behavior, command legality, DMA data-path behavior, completion, and error handling. Checker-only state tracks accepted beats and expected SRAM positions using external DUT interfaces.

**SVA source was implemented, but assertion execution is not claimed because the current web simulation environment does not support the required SVA constructs.** No SVA PASS result or assertion coverage is claimed. The checker is not included in the passing Icarus functional command above.

Integration requires an SVA-capable simulator and an explicit checker instance, including command signals and `enable_rlast_protocol_assertions`. Disable only the RLAST-placement protocol check for the intentional Early/Missing RLAST tests; keep DUT error-detection assertions enabled.

## 13. v1.0 Limitations

- Read DMA only; no Write DMA.
- INCR bursts only; no FIXED or WRAP bursts.
- No multiple transaction IDs or out-of-order responses.
- No descriptor queue, scatter-gather, or 2D stride.
- AXI source address must be beat aligned.
- Length must be nonzero and a multiple of `BEAT_BYTES`.
- The configured beat size must be a power of two. The documented/verified configuration uses 32-bit data.
- Unsupported commands are not rejected by a dedicated RTL validation interface; the integration environment must enforce the command contract.
- SRAM addresses are word addresses. The destination pointer wraps at `SRAM_ADDR_W`; the caller must provide a valid destination region and sufficient capacity.
- The SRAM interface accepts every asserted write enable; there is no SRAM backpressure.
- There is one active command and one outstanding read burst. There is no command queue, abort interface, retry mechanism, or hardware response timeout.
- The implementation supports full-word aligned transfers, not partial-word writes or byte strobes.
- Reported results establish directed functional simulation for the stated configuration. Synthesis, timing closure, formal proofs, hardware bring-up, and coverage closure are not reported.

## 14. Future Work

Possible future extensions include Write DMA, multiple outstanding reads, FIFO/backpressure support, a descriptor engine, scatter-gather, and integration into a 4x4 INT8 Matrix Accelerator. These are future directions, not v1.0 features.

```text
External Memory
      |
      v
AXI Read DMA
      |
      v
Input SRAM
      |
      v
Matrix Adapter
      |
      v
Input Skew
      |
      v
4x4 INT8 Systolic Array
```

## 15. Source Layout

```text
rtl/
  axi_read_dma.sv                 DMA top level with integrated FSM
  axi_read_dma_burst_manager.sv   Combinational burst planner
  axi_read_dma_fsm.sv             Separate FSM module; not used by top level

tb/
  tb_axi_read_dma.sv              Verified 13-test functional regression
  axi_read_dma_sva.sv             Optional assertion checker
  tb_axi_read_dma_burst_manager.sv Separate burst-manager testbench

docs/
  AXI_Read_DMA_v1_0_Specification_REGENERATED.pdf
```

The two RTL modules and the main directed testbench are sufficient for the documented functional simulation. The reported 13-test result applies to the main regression, not to an additional standalone burst-manager or SVA run.
