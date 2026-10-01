`timescale 1ns/1ps

module tb_axi_read_dma_burst_manager;

    localparam int AXI_ADDR_W = 32;
    localparam int AXI_DATA_W = 32;

    logic [AXI_ADDR_W-1:0] current_axi_addr;
    logic [31:0]           bytes_remaining;

    logic [AXI_ADDR_W-1:0] araddr;
    logic [7:0]            arlen;
    logic [31:0]           burst_bytes;
    logic [8:0]            burst_beats;


    axi_read_dma_burst_manager #(
        .AXI_ADDR_W (AXI_ADDR_W),
        .AXI_DATA_W (AXI_DATA_W)
    ) dut (
        .current_axi_addr (current_axi_addr),
        .bytes_remaining  (bytes_remaining),

        .araddr            (araddr),
        .arlen             (arlen),
        .burst_bytes       (burst_bytes),
        .burst_beats       (burst_beats)
    );


    task automatic run_test(
        input string                  test_name,
        input logic [AXI_ADDR_W-1:0] addr,
        input logic [31:0]           remaining,
        input logic [31:0]           expected_bytes,
        input logic [8:0]            expected_beats,
        input logic [7:0]            expected_arlen
    );

        begin

            current_axi_addr = addr;
            bytes_remaining  = remaining;

            #1;

            if ((araddr      !== addr)           ||
                (burst_bytes !== expected_bytes) ||
                (burst_beats !== expected_beats) ||
                (arlen       !== expected_arlen)) begin

                $display("FAIL: %s", test_name);

                $display(
                    "  addr:  expected=%h actual=%h",
                    addr,
                    araddr
                );

                $display(
                    "  bytes: expected=%0d actual=%0d",
                    expected_bytes,
                    burst_bytes
                );

                $display(
                    "  beats: expected=%0d actual=%0d",
                    expected_beats,
                    burst_beats
                );

                $display(
                    "  arlen: expected=%0d actual=%0d",
                    expected_arlen,
                    arlen
                );

            end
            else begin

                $display("PASS: %s", test_name);

            end

        end

    endtask


    initial begin

        current_axi_addr = '0;
        bytes_remaining  = '0;

        #1;


        // -------------------------------------------------
        // Test 1: single beat
        // -------------------------------------------------
        run_test(
            "single beat",
            32'h0000_1000,
            32'd4,
            32'd4,
            9'd1,
            8'd0
        );


        // -------------------------------------------------
        // Test 2: normal 16-beat burst
        // -------------------------------------------------
        run_test(
            "16 beats",
            32'h0000_1000,
            32'd64,
            32'd64,
            9'd16,
            8'd15
        );


        // -------------------------------------------------
        // Test 3: maximum AXI4 burst
        // -------------------------------------------------
        run_test(
            "maximum 256-beat burst",
            32'h0000_1000,
            32'd1024,
            32'd1024,
            9'd256,
            8'd255
        );


        // -------------------------------------------------
        // Test 4: 257 beats must be split
        // -------------------------------------------------
        run_test(
            "257 beats limited to 256",
            32'h0000_1000,
            32'd1028,
            32'd1024,
            9'd256,
            8'd255
        );


        // -------------------------------------------------
        // Test 5: 4KB boundary split
        // -------------------------------------------------
        run_test(
            "4KB boundary split",
            32'h0000_0F00,
            32'd3000,
            32'd256,
            9'd64,
            8'd63
        );


        // -------------------------------------------------
        // Test 6: address exactly at 4KB boundary
        // -------------------------------------------------
        run_test(
            "exact 4KB boundary",
            32'h0000_1000,
            32'd3000,
            32'd1024,
            9'd256,
            8'd255
        );


        // -------------------------------------------------
        // Test 7: final partial burst
        // -------------------------------------------------
        run_test(
            "final partial burst",
            32'h0000_1800,
            32'd696,
            32'd696,
            9'd174,
            8'd173
        );


        $display("");
        $display("All Burst Manager tests completed.");

        $finish;

    end

endmodule