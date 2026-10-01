`timescale 1ns/1ps
module tb_axi_read_dma;
    localparam int AXI_ADDR_W = 32;
    localparam int AXI_DATA_W = 32;
    localparam int SRAM_ADDR_W = 16;
    localparam int TIMEOUT_CYCLES = 200;
    localparam int MAX_BEATS = 750;
    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;
    localparam logic [1:0] AXI_RESP_EXOKAY = 2'b01;
    localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;
    localparam logic [1:0] AXI_RESP_DECERR = 2'b11;
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;
    localparam logic [31:0] SENTINEL = 32'h5A5A_A5A5;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;
    logic cmd_valid = 0, cmd_ready;
    logic [AXI_ADDR_W-1:0] cmd_axi_addr = 0;
    logic [SRAM_ADDR_W-1:0] cmd_sram_addr = 0;
    logic [31:0] cmd_len_bytes = 0;
    logic busy, done, error;
    logic [AXI_ADDR_W-1:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid, m_axi_arready = 0;
    logic [AXI_DATA_W-1:0] m_axi_rdata = 0;
    logic [1:0] m_axi_rresp = AXI_RESP_OKAY;
    logic m_axi_rlast = 0, m_axi_rvalid = 0, m_axi_rready;
    logic sram_we;
    logic [SRAM_ADDR_W-1:0] sram_waddr;
    logic [AXI_DATA_W-1:0] sram_wdata;

    axi_read_dma #(.AXI_ADDR_W(AXI_ADDR_W),
                   .AXI_DATA_W(AXI_DATA_W),
                   .SRAM_ADDR_W(SRAM_ADDR_W)) dut (.*);

    logic [AXI_DATA_W-1:0] sram_mem [0:(1<<SRAM_ADDR_W)-1];
    logic [31:0] data_plan [0:MAX_BEATS-1];
    logic [1:0] resp_plan [0:MAX_BEATS-1];
    logic last_plan [0:MAX_BEATS-1];
    logic [31:0] ar_plan [0:3];
    int burst_plan [0:3];
    logic [31:0] source_addr;
    logic [15:0] destination;
    int total_beats, total_bursts, expected_writes;
    int cmd_count = 0, ar_count = 0, r_count = 0;
    int write_count = 0, done_count = 0;
    int burst_received = 0, burst_limit = 0;
    bit active = 0, previous_done = 0, stalled_ar = 0;
    bit model_error = 0;
    logic [44:0] held_ar;
    string test_name = "Reset";
    string names [0:12];
    bit passed [0:12];

    task automatic fail(input string message);
        $fatal(1, "FAIL: %s: %s (time=%0t)", test_name, message, $time);
    endtask

    task automatic check_bit(input string label_text,
                             input logic actual, input logic expected);
        if (actual !== expected)
            fail($sformatf("%s expected=%b actual=%b", label_text, expected, actual));
    endtask

    task automatic check_ar(input int index);
        int beats, bytes_in_burst;
        logic [AXI_ADDR_W+13-1:0] ar_sample;
        // Materialize the sampled payload before checking for X/Z.
        // Avoid Icarus evaluation of a concatenation temporary in $isunknown.
        ar_sample = {m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst};
        if ($isunknown(ar_sample))
            fail($sformatf("AR[%0d] expected=known fields actual addr=%h len=%h size=%h burst=%h (X/Z)",
                 index, ar_sample[AXI_ADDR_W+12:13], ar_sample[12:5],
                 ar_sample[4:2], ar_sample[1:0]));
        if (m_axi_araddr !== ar_plan[index] ||
            m_axi_arlen !== (burst_plan[index]-1) ||
            m_axi_arsize !== 3'd2 || m_axi_arburst !== AXI_BURST_INCR)
            fail($sformatf("AR[%0d] expected addr=%h len=%0d size=2 burst=01; actual addr=%h len=%0d size=%0d burst=%b",
                 index, ar_plan[index], burst_plan[index]-1,
                 m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst));
        beats = int'(m_axi_arlen) + 1;
        bytes_in_burst = beats * (1 << m_axi_arsize);
        if (beats > 256 || beats < 1)
            fail($sformatf("AR[%0d] expected beats=1..256 actual=%0d", index, beats));
        if (int'(m_axi_araddr[11:0]) + bytes_in_burst > 4096)
            fail($sformatf("AR[%0d] expected 4KB end<=4096 actual=%0d addr=%h",
                 index, int'(m_axi_araddr[11:0])+bytes_in_burst, m_axi_araddr));
    endtask

    // Capture writes and handshakes BEFORE DUT NBA updates. All stimulus
    // changes on negedges. SRAM uses NBA, so tasks inspect memory later.
    // Only error/busy/ready post-update checks below use a #1 delay.
    logic [6:0] control_sample;
    always @(posedge clk) begin
        if (!rst_n) begin
            active = 0;
            previous_done = 0;
            stalled_ar = 0;
            model_error = 0;
            cmd_count = 0;
            ar_count = 0;
            r_count = 0;
            write_count = 0;
            done_count = 0;
            burst_received = 0;
            burst_limit = 0;
        end else begin
            control_sample = {cmd_ready, busy, done, error,
                              m_axi_arvalid, m_axi_rready, sram_we};
            if ($isunknown(control_sample))
                fail("Control outputs expected=known actual=X/Z");
            check_bit("error before edge", error, model_error);
            if (previous_done) check_bit("done pulse next cycle", done, 0);
            check_bit("busy before edge", busy, active);
            check_bit("cmd_ready before edge", cmd_ready, !active);
            if (active && sram_waddr !== (destination + r_count))
                fail($sformatf("SRAM pointer beat=%0d expected=%h actual=%h",
                     r_count, destination+r_count, sram_waddr));

            if (cmd_valid === 1'b1 && cmd_ready === 1'b1) begin
                if (active || cmd_count != 0)
                    fail($sformatf("command count expected=0 actual=%0d active=%b", cmd_count, active));
                active = 1;
                cmd_count++;
                model_error = 0;
            end

            if (stalled_ar) begin
                check_bit("stalled ARVALID", m_axi_arvalid, 1);
                if ({m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst} !== held_ar)
                    fail($sformatf("stalled AR fields expected=%h actual=%h", held_ar,
                         {m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst}));
            end
            stalled_ar = m_axi_arvalid && !m_axi_arready;
            if (stalled_ar)
                held_ar = {m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst};

            if (m_axi_arvalid === 1'b1 && m_axi_arready === 1'b1) begin
                if (!active || ar_count >= total_bursts || burst_received != burst_limit)
                    fail($sformatf("unexpected AR index=%0d active=%b previous beats expected=%0d actual=%0d",
                         ar_count, active, burst_limit, burst_received));
                check_ar(ar_count);
                burst_limit = burst_plan[ar_count];
                burst_received = 0;
                ar_count++;
            end

            check_bit("sram_we", sram_we,
                      m_axi_rvalid && m_axi_rready && (m_axi_rresp == AXI_RESP_OKAY));
            if (m_axi_rvalid === 1'b1 && m_axi_rready === 1'b1) begin
                if (!active || ar_count == 0 || r_count >= total_beats ||
                    burst_received >= burst_limit)
                    fail($sformatf("unexpected R beat=%0d burst beat=%0d limit=%0d active=%b",
                         r_count, burst_received, burst_limit, active));
                if (m_axi_rdata !== data_plan[r_count] ||
                    m_axi_rresp !== resp_plan[r_count] ||
                    m_axi_rlast !== last_plan[r_count])
                    fail($sformatf("R[%0d] expected data=%h resp=%b last=%b actual data=%h resp=%b last=%b",
                         r_count, data_plan[r_count], resp_plan[r_count], last_plan[r_count],
                         m_axi_rdata, m_axi_rresp, m_axi_rlast));
                // Check the visible pointer on EVERY accepted beat, even
                // if the response suppresses that beat's SRAM write.
                if (sram_waddr !== (destination + r_count))
                    fail($sformatf("R[%0d] SRAM address expected=%h actual=%h",
                         r_count, destination+r_count, sram_waddr));
                if (m_axi_rresp !== AXI_RESP_OKAY ||
                    m_axi_rlast !== (burst_received == burst_limit-1))
                    model_error = 1;
                burst_received++;
            end
            if (sram_we) begin
                if (!active || !(m_axi_rvalid && m_axi_rready))
                    fail("SRAM write expected=accepted R beat actual=unsolicited write");
                if (sram_wdata !== data_plan[r_count])
                    fail($sformatf("SRAM beat=%0d addr=%h expected=%h actual=%h",
                         r_count, sram_waddr, data_plan[r_count], sram_wdata));
                sram_mem[sram_waddr] <= sram_wdata;
                write_count++;
            end
            if (m_axi_rvalid === 1'b1 && m_axi_rready === 1'b1) r_count++;

            if (done) begin
                if (!active || done_count != 0 || r_count != total_beats ||
                    ar_count != total_bursts || write_count != expected_writes)
                    fail($sformatf("done expected active=1 count=0 AR/R/write=%0d/%0d/%0d actual active=%b count=%0d AR/R/write=%0d/%0d/%0d",
                         total_bursts,total_beats,expected_writes,active,done_count,
                         ar_count,r_count,write_count));
                done_count++;
                active = 0;
            end
            previous_done = done;

            // Check registered error on the very edge that clears/sets it.
            // active remains true through COMPLETE, then clears as it retires.
            #1;
            check_bit("error after edge", error, model_error);
            check_bit("busy after edge", busy, active);
            check_bit("cmd_ready after edge", cmd_ready, !active);
            if (done === 1'b1 && r_count != total_beats)
                fail($sformatf("early done expected R=%0d actual=%0d", total_beats,r_count));
        end
    end

    task automatic reset_dut();
        @(negedge clk);
        rst_n = 0;
        cmd_valid = 0;
        cmd_axi_addr = 0;
        cmd_sram_addr = 0;
        cmd_len_bytes = 0;
        m_axi_arready = 0;
        m_axi_rvalid = 0;
        m_axi_rdata = 0;
        m_axi_rresp = AXI_RESP_OKAY;
        m_axi_rlast = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
        check_bit("reset busy", busy, 0);
        check_bit("reset done", done, 0);
        check_bit("reset error", error, 0);
    endtask

    task automatic send_command(input logic [31:0] axi_addr,
                                input logic [15:0] sram_addr,
                                input logic [31:0] len_bytes);
        bit accepted;
        @(negedge clk);
        cmd_axi_addr = axi_addr;
        cmd_sram_addr = sram_addr;
        cmd_len_bytes = len_bytes;
        cmd_valid = 1;
        accepted = 0;
        for (int n=0; (n<TIMEOUT_CYCLES) && !accepted; n++) begin
            @(posedge clk);
            if (cmd_ready === 1'b1) begin accepted=1; end
        end
        if (!accepted) fail("command timeout expected=READY handshake actual=none");
        @(negedge clk);
        cmd_valid = 0;
        cmd_axi_addr = 0;
        cmd_sram_addr = 0;
        cmd_len_bytes = 0;
        check_bit("busy after command", busy, 1);
        check_bit("error cleared on command", error, 0);
    endtask

    task automatic accept_ar(input int stall_cycles = 0);
        bit found, accepted;
        found = 0;
        for (int n=0; (n<TIMEOUT_CYCLES) && !found; n++) begin
            @(negedge clk);
            if (m_axi_arvalid === 1'b1) begin found=1; end
        end
        if (!found) fail("AR timeout expected=ARVALID actual=none");
        repeat (stall_cycles) @(negedge clk);
        m_axi_arready = 1;
        accepted = 0;
        for (int n=0; (n<TIMEOUT_CYCLES) && !accepted; n++) begin
            @(posedge clk);
            if (m_axi_arvalid === 1'b1) begin accepted=1; end
        end
        if (!accepted) fail("AR timeout expected=handshake actual=none");
        @(negedge clk);
        m_axi_arready = 0;
    endtask

    task automatic send_r_beat(input logic [AXI_DATA_W-1:0] data,
                               input logic [1:0] resp,
                               input logic last);
        bit accepted;
        @(negedge clk);
        m_axi_rdata = data;
        m_axi_rresp = resp;
        m_axi_rlast = last;
        m_axi_rvalid = 1;
        accepted = 0;
        for (int n=0; (n<TIMEOUT_CYCLES) && !accepted; n++) begin
            @(posedge clk);
            if (m_axi_rready === 1'b1) begin accepted=1; end
        end
        if (!accepted) fail("R timeout expected=RREADY handshake actual=none");
        @(negedge clk);
        m_axi_rvalid = 0;
        m_axi_rdata = 0;
        m_axi_rresp = AXI_RESP_OKAY;
        m_axi_rlast = 0;
    endtask

    task automatic idle_gap(input int cycles);
        int saved_reads, saved_writes;
        saved_reads = r_count;
        saved_writes = write_count;
        // send_r_beat's initial negedge already adds one idle posedge.
        // Wait cycles-1 here to obtain exactly the requested total gap.
        repeat (cycles-1) @(negedge clk);
        if (r_count != saved_reads || write_count != saved_writes)
            fail($sformatf("gap expected R/write=%0d/%0d actual=%0d/%0d",
                 saved_reads,saved_writes,r_count,write_count));
    endtask

    task automatic wait_for_done();
        bit observed;
        observed = 0;
        for (int n=0; (n<TIMEOUT_CYCLES) && !observed; n++) begin
            @(negedge clk);
            if (done_count == 1) begin observed=1; end
        end
        if (!observed) fail("done timeout expected=one pulse actual=none");
        check_bit("done retired", done, 0);
        check_bit("busy retired", busy, 0);
        check_bit("idle ready", cmd_ready, 1);
        repeat (3) @(negedge clk);
        if (done_count != 1 || cmd_count != 1 || ar_count != total_bursts ||
            r_count != total_beats || write_count != expected_writes)
            fail($sformatf("counts expected cmd/done/AR/R/write=1/1/%0d/%0d/%0d actual=%0d/%0d/%0d/%0d/%0d",
                 total_bursts,total_beats,expected_writes,cmd_count,done_count,
                 ar_count,r_count,write_count));
        check_bit("final sticky error", error, model_error);
        if ({cmd_valid,m_axi_arready,m_axi_rvalid,m_axi_arvalid,
             m_axi_rready,sram_we,busy,done} !== 8'b0)
            fail($sformatf("clean interfaces expected=00 actual=%h",
                 {cmd_valid,m_axi_arready,m_axi_rvalid,m_axi_arvalid,
                  m_axi_rready,sram_we,busy,done}));
    endtask

    task automatic check_sram(input logic [15:0] address,
                              input logic [31:0] expected);
        if (sram_mem[address] !== expected)
            fail($sformatf("SRAM[%h] expected=%h actual=%h",
                 address,expected,sram_mem[address]));
    endtask

    task automatic begin_test(input int index, input logic [31:0] src,
                              input logic [15:0] dst, input int beats,
                              input int bursts, input logic [31:0] seed);
        @(negedge clk);
        test_name = names[index];
        check_bit("before command busy", busy, 0);
        check_bit("before command done", done, 0);
        check_bit("before command ready", cmd_ready, 1);
        source_addr = src;
        destination = dst;
        total_beats = beats;
        total_bursts = bursts;
        expected_writes = beats;
        cmd_count = 0;
        ar_count = 0;
        r_count = 0;
        write_count = 0;
        done_count = 0;
        burst_received = 0;
        burst_limit = 0;
        // Do not reset model_error: idle error must remain sticky between
        // commands. Only the next accepted command clears it.
        for (int i=0; i<beats; i++) begin
            data_plan[i] = seed+i;
            resp_plan[i] = AXI_RESP_OKAY;
            last_plan[i] = 0;
            sram_mem[dst+i] = SENTINEL;
        end
        for (int b=0; b<4; b++) begin ar_plan[b]=0; burst_plan[b]=0; end
        ar_plan[0] = src;
        burst_plan[0] = beats;
    endtask

    task automatic run_test(input int index, input bit gaps = 0,
                            input int ar_stall = 0);
        int offset, planned_sum;
        logic [31:0] expected;
        planned_sum = 0;
        for (int b=0; b<total_bursts; b++) begin
            if (burst_plan[b] < 1 || burst_plan[b] > 256)
                fail($sformatf("plan burst=%0d expected=1..256 actual=%0d", b,burst_plan[b]));
            planned_sum += burst_plan[b];
            last_plan[planned_sum-1] = 1;
        end
        if (planned_sum != total_beats)
            fail($sformatf("plan sum expected=%0d actual=%0d",total_beats,planned_sum));
        // Intentional RLAST protocol violations for tests 11 and 12.
        if (index == 10) last_plan[1] = 1;
        if (index == 11) last_plan[3] = 0;
        send_command(source_addr,destination,total_beats*4);
        offset = 0;
        for (int b=0; b<total_bursts; b++) begin
            accept_ar(ar_stall);
            for (int i=0; i<burst_plan[b]; i++) begin
                send_r_beat(data_plan[offset],resp_plan[offset],last_plan[offset]);
                offset++;
                if (gaps && offset < total_beats) begin
                    case (offset)
                        1: idle_gap(2);
                        2: idle_gap(1);
                        3: idle_gap(3);
                    endcase
                end
            end
            if (b < total_bursts-1) begin
                check_bit("between bursts done", done, 0);
                check_bit("between bursts busy", busy, 1);
            end
        end
        wait_for_done();
        for (int i=0; i<total_beats; i++) begin
            expected = (resp_plan[i] == AXI_RESP_OKAY) ? data_plan[i] : SENTINEL;
            check_sram(destination+i,expected);
        end
        passed[index] = 1;
        $display("PASS: %s",test_name);
    endtask

    initial begin
        names[0] = "Single-beat transfer";
        names[1] = "Four-beat transfer";
        names[2] = "RVALID stall test";
        names[3] = "ARREADY backpressure test";
        names[4] = "Maximum 256-beat burst";
        names[5] = "257-beat two-burst transfer";
        names[6] = "4KB boundary split";
        names[7] = "Combined 4KB and 256-beat splitting";
        names[8] = "RRESP SLVERR handling";
        names[9] = "RRESP DECERR handling";
        names[10] = "Early RLAST detection";
        names[11] = "Missing RLAST detection";
        names[12] = "Sticky error clear on new command";
        for (int i=0; i<13; i++) passed[i]=0;
        reset_dut();

        begin_test(0,32'h1000,16'h0010,1,1,32'h12345678);
        run_test(0);
        begin_test(1,32'h1000,16'h0020,4,1,0);
        for (int i=0; i<4; i++) data_plan[i]=32'h11111111*(i+1);
        run_test(1);
        begin_test(2,32'h1000,16'h0030,4,1,0);
        for (int i=0; i<4; i++) data_plan[i]=32'h11111111*(i+1);
        run_test(2,1);
        begin_test(3,32'h1000,16'h0040,4,1,32'h44000000);
        run_test(3,0,5);
        begin_test(4,32'h2000,16'h0100,256,1,32'hA0000000);
        run_test(4);
        begin_test(5,32'h3000,16'h0200,257,2,32'hB0000000);
        ar_plan[0]=32'h3000; burst_plan[0]=256;
        ar_plan[1]=32'h3400; burst_plan[1]=1;
        run_test(5);
        begin_test(6,32'h0F00,16'h0400,128,2,32'hC0000000);
        ar_plan[0]=32'h0F00; burst_plan[0]=64;
        ar_plan[1]=32'h1000; burst_plan[1]=64;
        run_test(6);
        begin_test(7,32'h0F00,16'h0800,750,4,32'hD0000000);
        ar_plan[0]=32'h0F00; burst_plan[0]=64;
        ar_plan[1]=32'h1000; burst_plan[1]=256;
        ar_plan[2]=32'h1400; burst_plan[2]=256;
        ar_plan[3]=32'h1800; burst_plan[3]=174;
        run_test(7);
        begin_test(8,32'h2000,16'h1000,4,1,32'hE0000000);
        resp_plan[2]=AXI_RESP_SLVERR; expected_writes=3;
        run_test(8);
        begin_test(9,32'h2100,16'h1100,4,1,32'hE1000000);
        resp_plan[1]=AXI_RESP_DECERR; expected_writes=3;
        run_test(9);
        begin_test(10,32'h2200,16'h1200,4,1,32'hE2000000);
        run_test(10);
        begin_test(11,32'h2300,16'h1300,4,1,32'hE3000000);
        run_test(11);
        check_bit("sticky error before recovery command",error,1);
        begin_test(12,32'h2400,16'h1400,4,1,32'hF0000000);
        check_bit("sticky error retained before acceptance",error,1);
        run_test(12);
        check_bit("recovery error",error,0);

        $display("==================================================");
        $display("AXI READ DMA v1.0 DIRECTED REGRESSION");
        $display("==================================================");
        for (int i=0; i<13; i++) begin
            if (!passed[i]) fail($sformatf("test[%0d] expected=PASS actual=not run",i));
            $display("PASS: %s",names[i]);
        end
        $display("==================================================");
        $display("ALL TESTS PASSED");
        $display("==================================================");
        $finish;
    end

    initial begin
        #1000000;
        fail("global watchdog expected=regression complete actual=timeout");
    end
endmodule
