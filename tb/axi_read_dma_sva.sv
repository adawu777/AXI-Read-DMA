`timescale 1ns/1ps

module axi_read_dma_sva #(
    parameter int AXI_ADDR_W  = 32,
    parameter int AXI_DATA_W  = 32,
    parameter int SRAM_ADDR_W = 16
) (
    input logic clk,
    input logic rst_n,
    input logic cmd_valid,
    input logic cmd_ready,
    input logic [AXI_ADDR_W-1:0] cmd_axi_addr,
    input logic [SRAM_ADDR_W-1:0] cmd_sram_addr,
    input logic [31:0] cmd_len_bytes,
    input logic enable_rlast_protocol_assertions,
    input logic busy,
    input logic done,
    input logic error,
    input logic [AXI_ADDR_W-1:0] m_axi_araddr,
    input logic [7:0] m_axi_arlen,
    input logic [2:0] m_axi_arsize,
    input logic [1:0] m_axi_arburst,
    input logic m_axi_arvalid,
    input logic m_axi_arready,
    input logic [AXI_DATA_W-1:0] m_axi_rdata,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast,
    input logic m_axi_rvalid,
    input logic m_axi_rready,
    input logic sram_we,
    input logic [SRAM_ADDR_W-1:0] sram_waddr,
    input logic [AXI_DATA_W-1:0] sram_wdata
);
    // 1. Constants
    localparam int BEAT_BYTES = AXI_DATA_W / 8;
    localparam int BEAT_SHIFT = $clog2(BEAT_BYTES);
    localparam logic [2:0] EXPECTED_ARSIZE = BEAT_SHIFT;
    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;
    // Mask avoids a zero-width part-select when BEAT_BYTES is one.
    localparam logic [AXI_ADDR_W-1:0] ALIGN_MASK = BEAT_BYTES - 1;

    logic [8:0] ar_beats;
    logic [16:0] burst_bytes;
    logic [17:0] boundary_end;
    logic cmd_fire;
    assign cmd_fire = cmd_valid && cmd_ready;
    assign ar_beats = {1'b0, m_axi_arlen} + 9'd1;
    // Widen BEFORE shifting. ARSIZE up to 7 permits 32768 burst bytes.
    assign burst_bytes = {8'b0, ar_beats} << m_axi_arsize;
    assign boundary_end = {6'b0, m_axi_araddr[11:0]} + {1'b0, burst_bytes};

    initial begin
        if (AXI_ADDR_W < 12 || SRAM_ADDR_W < 1 || AXI_DATA_W < 8 ||
            AXI_DATA_W % 8 != 0 || BEAT_BYTES > 128 ||
            (BEAT_BYTES & (BEAT_BYTES - 1)) != 0)
            $fatal(1, "AXI DMA SVA: unsupported parameters: require address width >=12 and a power-of-two beat size of 1..128 bytes");
    end

    // 2. Checker state: verification only; never drives DUT signals.
    // NBA updates preserve the pre-edge pointer/count seen by assertions.
    logic [SRAM_ADDR_W-1:0] initial_sram_addr, expected_sram_addr;
    logic [SRAM_ADDR_W-1:0] previous_sram_waddr;
    logic previous_write_valid;
    logic [31:0] expected_total_beats, accepted_r_beats;
    logic [8:0] expected_burst_beats, accepted_burst_beats;
    logic burst_active, command_active, expected_last;
    logic [SRAM_ADDR_W-1:0] final_sram_addr;
    logic r_fire, ar_fire;
    assign r_fire = m_axi_rvalid && m_axi_rready;
    assign ar_fire = m_axi_arvalid && m_axi_arready;
    assign expected_last = burst_active &&
        (accepted_burst_beats == expected_burst_beats - 9'd1);
    // Address arithmetic intentionally wraps to SRAM_ADDR_W, like the DUT.
    assign final_sram_addr = initial_sram_addr +
        SRAM_ADDR_W'(expected_total_beats);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            initial_sram_addr <= '0;
            expected_sram_addr <= '0;
            previous_sram_waddr <= '0;
            previous_write_valid <= 1'b0;
            expected_total_beats <= '0;
            accepted_r_beats <= '0;
            expected_burst_beats <= '0;
            accepted_burst_beats <= '0;
            burst_active <= 1'b0;
            command_active <= 1'b0;
        end else if (cmd_fire) begin
            initial_sram_addr <= cmd_sram_addr;
            expected_sram_addr <= cmd_sram_addr;
            previous_write_valid <= 1'b0;
            expected_total_beats <= cmd_len_bytes / BEAT_BYTES;
            accepted_r_beats <= '0;
            expected_burst_beats <= '0;
            accepted_burst_beats <= '0;
            burst_active <= 1'b0;
            command_active <= 1'b1;
        end else begin
            if (r_fire) begin
                expected_sram_addr <= expected_sram_addr + 1'b1;
                accepted_r_beats <= accepted_r_beats + 1'b1;
            end
            if (sram_we) begin
                previous_sram_waddr <= sram_waddr;
                previous_write_valid <= 1'b1;
            end else if (r_fire) begin
                // A skipped write breaks adjacency of successful R beats.
                // RVALID stalls leave previous_write_valid unchanged.
                previous_write_valid <= 1'b0;
            end
            if (ar_fire) begin
                expected_burst_beats <= ar_beats;
                accepted_burst_beats <= '0;
                burst_active <= 1'b1;
            end else if (r_fire) begin
                accepted_burst_beats <= accepted_burst_beats + 1'b1;
                // Programmed count closes the burst even on bad RLAST.
                if (expected_last) burst_active <= 1'b0;
            end
            if (done) command_active <= 1'b0;
        end
    end

    default clocking cb @(posedge clk);
    endclocking
    default disable iff (!rst_n);

    // 3. AXI protocol assertions
    property p_arvalid_hold;
        m_axi_arvalid && !m_axi_arready |=> m_axi_arvalid;
    endproperty
    a_arvalid_hold: assert property (p_arvalid_hold)
        else $error("AXI DMA SVA: ARVALID dropped before ARREADY");

    property p_ar_payload_stable;
        m_axi_arvalid && !m_axi_arready |=>
            $stable({m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst});
    endproperty
    a_ar_payload_stable: assert property (p_ar_payload_stable)
        else $error("AXI DMA SVA: AR payload changed while stalled");

    property p_arburst_incr;
        m_axi_arvalid |-> (m_axi_arburst == AXI_BURST_INCR);
    endproperty
    a_arburst_incr: assert property (p_arburst_incr)
        else $error("AXI DMA SVA: ARBURST expected=01 actual=%b", $sampled(m_axi_arburst));

    property p_arsize_matches_data_width;
        m_axi_arvalid |-> (m_axi_arsize == EXPECTED_ARSIZE);
    endproperty
    a_arsize_matches_data_width: assert property (p_arsize_matches_data_width)
        else $error("AXI DMA SVA: ARSIZE expected=%0d actual=%0d",
                    EXPECTED_ARSIZE, $sampled(m_axi_arsize));

    property p_maximum_burst;
        m_axi_arvalid && m_axi_arready |->
            (ar_beats >= 9'd1 && ar_beats <= 9'd256);
    endproperty
    a_maximum_burst: assert property (p_maximum_burst)
        else $error("AXI DMA SVA: burst beats expected=1..256 actual=%0d", $sampled(ar_beats));

    property p_no_4kb_crossing;
        m_axi_arvalid && m_axi_arready |-> (boundary_end <= 18'd4096);
    endproperty
    a_no_4kb_crossing: assert property (p_no_4kb_crossing)
        else $error("AXI DMA SVA: 4KB crossing addr=%h bytes=%0d end=%0d (limit=4096)",
                    $sampled(m_axi_araddr), $sampled(burst_bytes), $sampled(boundary_end));

    property p_araddr_aligned;
        m_axi_arvalid && m_axi_arready |-> ((m_axi_araddr & ALIGN_MASK) == '0);
    endproperty
    a_araddr_aligned: assert property (p_araddr_aligned)
        else $error("AXI DMA SVA: ARADDR=%h is not aligned to %0d bytes",
                    $sampled(m_axi_araddr), BEAT_BYTES);

    // Only slave RLAST correctness is gated. DUT error detection stays on.
    property p_rlast_protocol_correct;
        enable_rlast_protocol_assertions && r_fire && burst_active |->
            (m_axi_rlast == expected_last);
    endproperty
    a_rlast_protocol_correct: assert property (p_rlast_protocol_correct)
        else $error("AXI DMA SVA: RLAST expected=%b actual=%b burst beat=%0d of %0d",
                    $sampled(expected_last), $sampled(m_axi_rlast),
                    $sampled(accepted_burst_beats), $sampled(expected_burst_beats));

    // 4. DMA command legality assertions -- COMMAND LEGALITY ASSERTIONS
    // Environment/spec checks, not guarantees for unsupported DUT inputs.
    property p_command_source_aligned;
        cmd_fire |-> ((cmd_axi_addr & ALIGN_MASK) == '0);
    endproperty
    a_command_source_aligned: assert property (p_command_source_aligned)
        else $error("Illegal DMA command: AXI source address is not beat aligned: addr=%h beat bytes=%0d",
                    $sampled(cmd_axi_addr), BEAT_BYTES);

    property p_command_length_aligned;
        cmd_fire |-> ((cmd_len_bytes % BEAT_BYTES) == 0);
    endproperty
    a_command_length_aligned: assert property (p_command_length_aligned)
        else $error("Illegal DMA command: length is not a multiple of beat size: length=%0d beat bytes=%0d",
                    $sampled(cmd_len_bytes), BEAT_BYTES);

    property p_command_nonzero_length;
        cmd_fire |-> (cmd_len_bytes != 0);
    endproperty
    a_command_nonzero_length: assert property (p_command_nonzero_length)
        else $error("Illegal DMA command: zero-length transfer is unsupported");

    // 5. DMA FUNCTIONAL ASSERTIONS -- DMA data-path assertions
    property p_sram_write_requires_r_handshake;
        sram_we |-> (m_axi_rvalid && m_axi_rready);
    endproperty
    a_sram_write_requires_r_handshake:
        assert property (p_sram_write_requires_r_handshake)
        else $error("AXI DMA SVA: SRAM write without accepted R beat");

    property p_sram_write_only_okay;
        sram_we |-> (m_axi_rresp == AXI_RESP_OKAY);
    endproperty
    a_sram_write_only_okay: assert property (p_sram_write_only_okay)
        else $error("AXI DMA SVA: SRAM write with non-OKAY RRESP=%b", $sampled(m_axi_rresp));

    property p_okay_beat_writes_sram;
        m_axi_rvalid && m_axi_rready && (m_axi_rresp == AXI_RESP_OKAY)
            |-> sram_we;
    endproperty
    a_okay_beat_writes_sram: assert property (p_okay_beat_writes_sram)
        else $error("AXI DMA SVA: accepted OKAY R beat did not write SRAM");

    property p_sram_data_matches_rdata;
        sram_we |-> (sram_wdata == m_axi_rdata);
    endproperty
    a_sram_data_matches_rdata: assert property (p_sram_data_matches_rdata)
        else $error("AXI DMA SVA: SRAM data expected=%h actual=%h address=%h",
                    $sampled(m_axi_rdata), $sampled(sram_wdata), $sampled(sram_waddr));

    property p_no_write_without_rvalid;
        !m_axi_rvalid |-> !sram_we;
    endproperty
    a_no_write_without_rvalid: assert property (p_no_write_without_rvalid)
        else $error("AXI DMA SVA: SRAM write while RVALID was low");
    property p_sram_address_matches_expected;
        sram_we |-> (command_active && sram_waddr == expected_sram_addr);
    endproperty
    a_sram_address_matches_expected: assert property (p_sram_address_matches_expected)
        else $error("AXI DMA SVA: SRAM beat=%0d address expected=%h actual=%h command active=%b",
                    $sampled(accepted_r_beats), $sampled(expected_sram_addr),
                    $sampled(sram_waddr), $sampled(command_active));

    property p_consecutive_successful_beats_increment_address;
        sram_we && previous_write_valid |->
            (sram_waddr == SRAM_ADDR_W'(previous_sram_waddr + 1'b1));
    endproperty
    a_consecutive_successful_beats_increment_address:
        assert property (p_consecutive_successful_beats_increment_address)
        else $error("AXI DMA SVA: adjacent successful R beats did not advance SRAM address: previous=%h actual=%h",
                    $sampled(previous_sram_waddr), $sampled(sram_waddr));

    property p_no_excess_r_beats;
        r_fire |-> (command_active && accepted_r_beats < expected_total_beats);
    endproperty
    a_no_excess_r_beats: assert property (p_no_excess_r_beats)
        else $error("AXI DMA SVA: excess R beat: accepted before edge=%0d requested=%0d active=%b",
                    $sampled(accepted_r_beats), $sampled(expected_total_beats), $sampled(command_active));

    property p_r_beat_within_burst;
        r_fire |-> (burst_active && accepted_burst_beats < expected_burst_beats);
    endproperty
    a_r_beat_within_burst: assert property (p_r_beat_within_burst)
        else $error("AXI DMA SVA: R handshake outside active burst or beyond ARLEN");

    property p_ar_requires_completed_previous_burst;
        ar_fire |-> (command_active && !burst_active);
    endproperty
    a_ar_requires_completed_previous_burst:
        assert property (p_ar_requires_completed_previous_burst)
        else $error("AXI DMA SVA: AR accepted without command or before previous burst completed");

    property p_idle_no_rready;
        !busy |-> !m_axi_rready;
    endproperty
    a_idle_no_rready: assert property (p_idle_no_rready)
        else $error("AXI DMA SVA: RREADY asserted while DMA idle");

    property p_idle_no_arvalid;
        !busy |-> !m_axi_arvalid;
    endproperty
    a_idle_no_arvalid: assert property (p_idle_no_arvalid)
        else $error("AXI DMA SVA: ARVALID asserted while DMA idle");

    // 6. DMA completion assertions
    property p_done_one_cycle;
        done |=> !done;
    endproperty
    a_done_one_cycle: assert property (p_done_one_cycle)
        else $error("AXI DMA SVA: done remained asserted for multiple cycles");

    property p_done_implies_busy;
        done |-> busy;
    endproperty
    a_done_implies_busy: assert property (p_done_implies_busy)
        else $error("AXI DMA SVA: done asserted while busy was low");

    property p_busy_blocks_commands;
        busy |-> !cmd_ready;
    endproperty
    a_busy_blocks_commands: assert property (p_busy_blocks_commands)
        else $error("AXI DMA SVA: cmd_ready asserted while busy");

    property p_idle_accepts_commands;
        !busy |-> cmd_ready;
    endproperty
    a_idle_accepts_commands: assert property (p_idle_accepts_commands)
        else $error("AXI DMA SVA: cmd_ready deasserted while idle");

    property p_command_starts_busy;
        cmd_fire |=> busy;
    endproperty
    a_command_starts_busy: assert property (p_command_starts_busy)
        else $error("AXI DMA SVA: accepted command did not start busy operation");

    property p_no_command_acceptance_while_busy;
        busy |-> !cmd_fire;
    endproperty
    a_no_command_acceptance_while_busy: assert property (p_no_command_acceptance_while_busy)
        else $error("AXI DMA SVA: command accepted while busy");

    property p_done_no_command_acceptance;
        done |-> !cmd_fire;
    endproperty
    a_done_no_command_acceptance: assert property (p_done_no_command_acceptance)
        else $error("AXI DMA SVA: done overlaps command acceptance");

    property p_done_after_all_beats;
        done |-> (command_active && accepted_r_beats == expected_total_beats);
    endproperty
    a_done_after_all_beats: assert property (p_done_after_all_beats)
        else $error("AXI DMA SVA: done beat count expected=%0d actual=%0d active=%b",
                    $sampled(expected_total_beats), $sampled(accepted_r_beats), $sampled(command_active));

    property p_done_sram_position_consistent;
        done |-> (expected_sram_addr == final_sram_addr);
    endproperty
    a_done_sram_position_consistent: assert property (p_done_sram_position_consistent)
        else $error("AXI DMA SVA: completion SRAM position expected=%h actual=%h",
                    $sampled(final_sram_addr), $sampled(expected_sram_addr));

    // 7. DMA error-handling assertions
    property p_error_sticky;
        error && !cmd_fire |=> error;
    endproperty
    a_error_sticky: assert property (p_error_sticky)
        else $error("AXI DMA SVA: sticky error cleared without a preceding command handshake");

    // cmd_fire at edge N clears error in NBA at N; visible at sample N+1.
    // The original sticky-error property exempts that edge N handshake.
    property p_bad_rresp_sets_error;
        r_fire && (m_axi_rresp != AXI_RESP_OKAY) |=> error;
    endproperty
    a_bad_rresp_sets_error: assert property (p_bad_rresp_sets_error)
        else $error("AXI DMA SVA: accepted non-OKAY response did not set error");

    // Never gated by enable_rlast_protocol_assertions: intentional malformed
    // RLAST must still trigger the DUT's sticky-error behavior.
    property p_rlast_mismatch_sets_error;
        r_fire && burst_active && (m_axi_rlast != expected_last) |=> error;
    endproperty
    a_rlast_mismatch_sets_error: assert property (p_rlast_mismatch_sets_error)
        else $error("AXI DMA SVA: RLAST mismatch did not set error");

    property p_bad_rresp_no_sram_write;
        r_fire && (m_axi_rresp != AXI_RESP_OKAY) |-> !sram_we;
    endproperty
    a_bad_rresp_no_sram_write: assert property (p_bad_rresp_no_sram_write)
        else $error("AXI DMA SVA: non-OKAY response generated SRAM write");

    // The preserved p_okay_beat_writes_sram checks the reverse direction:
    // every accepted OKAY response must generate a write in the same cycle.
endmodule
