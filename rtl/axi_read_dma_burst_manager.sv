module axi_read_dma_burst_manager #(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32
) (
    input  logic [AXI_ADDR_W-1:0] current_axi_addr,
    input  logic [31:0]           bytes_remaining,

    output logic [AXI_ADDR_W-1:0] araddr,
    output logic [7:0]            arlen,

    output logic [31:0]           burst_bytes,
    output logic [8:0]            burst_beats
);

    localparam int BEAT_BYTES =
        AXI_DATA_W / 8;

    localparam int BEAT_SHIFT =
        $clog2(BEAT_BYTES);

    localparam int MAX_BURST_BEATS =
        256;

    localparam int MAX_BURST_BYTES =
        MAX_BURST_BEATS * BEAT_BYTES;


    logic [12:0] bytes_to_4kb;


    always_comb begin

        // -------------------------------------------------
        // Current AXI burst always starts at current address
        // -------------------------------------------------
        araddr = current_axi_addr;


        // -------------------------------------------------
        // Number of bytes available before next 4KB boundary
        // -------------------------------------------------
        bytes_to_4kb =
            13'd4096 -
            {1'b0, current_axi_addr[11:0]};


        // -------------------------------------------------
        // Start with all remaining bytes
        // -------------------------------------------------
        burst_bytes = bytes_remaining;


        // -------------------------------------------------
        // AXI4 INCR burst:
        // maximum 256 beats
        // -------------------------------------------------
        if (burst_bytes > MAX_BURST_BYTES)
            burst_bytes = MAX_BURST_BYTES;


        // -------------------------------------------------
        // AXI burst must not cross a 4KB boundary
        // -------------------------------------------------
        if (burst_bytes > bytes_to_4kb)
            burst_bytes = bytes_to_4kb;


        // -------------------------------------------------
        // Convert bytes to beats
        //
        // BEAT_BYTES must be a power of two.
        // Example:
        // AXI_DATA_W = 32
        // BEAT_BYTES = 4
        // BEAT_SHIFT = 2
        // -------------------------------------------------
        burst_beats =
            burst_bytes >> BEAT_SHIFT;


        // -------------------------------------------------
        // AXI ARLEN encoding:
        //
        // number of beats = ARLEN + 1
        // -------------------------------------------------
        if (burst_beats != 0)
            arlen = burst_beats - 1'b1;
        else
            arlen = 8'd0;

    end

endmodule