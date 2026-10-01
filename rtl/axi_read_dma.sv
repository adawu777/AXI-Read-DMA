module axi_read_dma #(
    parameter int AXI_ADDR_W  = 32,
    parameter int AXI_DATA_W  = 32,
    parameter int SRAM_ADDR_W = 16
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ---------------------------------------------------------
    // DMA Command Interface
    // ---------------------------------------------------------

    input  logic                     cmd_valid,
    output logic                     cmd_ready,

    input  logic [AXI_ADDR_W-1:0]    cmd_axi_addr,
    input  logic [SRAM_ADDR_W-1:0]   cmd_sram_addr,
    input  logic [31:0]              cmd_len_bytes,

    // ---------------------------------------------------------
    // DMA Status
    // ---------------------------------------------------------

    output logic                     busy,
    output logic                     done,
    output logic                     error,

    // ---------------------------------------------------------
    // AXI4 Read Address Channel
    // ---------------------------------------------------------

    output logic [AXI_ADDR_W-1:0]    m_axi_araddr,
    output logic [7:0]               m_axi_arlen,
    output logic [2:0]               m_axi_arsize,
    output logic [1:0]               m_axi_arburst,
    output logic                     m_axi_arvalid,
    input  logic                     m_axi_arready,

    // ---------------------------------------------------------
    // AXI4 Read Data Channel
    // ---------------------------------------------------------

    input  logic [AXI_DATA_W-1:0]    m_axi_rdata,
    input  logic [1:0]               m_axi_rresp,
    input  logic                     m_axi_rlast,
    input  logic                     m_axi_rvalid,
    output logic                     m_axi_rready,

    // ---------------------------------------------------------
    // SRAM Write Interface
    // ---------------------------------------------------------

    output logic                     sram_we,
    output logic [SRAM_ADDR_W-1:0]   sram_waddr,
    output logic [AXI_DATA_W-1:0]    sram_wdata
);


    // =========================================================
    // Local Parameters
    // =========================================================

    localparam int BEAT_BYTES =
        AXI_DATA_W / 8;

    localparam logic [2:0] AXI_ARSIZE =
        $clog2(BEAT_BYTES);

    localparam logic [1:0] AXI_BURST_INCR =
        2'b01;

    localparam logic [1:0] AXI_RESP_OKAY =
        2'b00;


    // =========================================================
    // FSM
    // =========================================================

    typedef enum logic [2:0] {
        IDLE,
        PREPARE_BURST,
        SEND_AR,
        RECV_R,
        COMPLETE
    } state_t;

    state_t state;
    state_t next_state;


    // =========================================================
    // DMA State Registers
    // =========================================================

    logic [AXI_ADDR_W-1:0]  current_axi_addr;
    logic [31:0]            bytes_remaining;
    logic [SRAM_ADDR_W-1:0] sram_wr_ptr;


    // =========================================================
    // Burst Manager Outputs
    // =========================================================

    logic [AXI_ADDR_W-1:0] burst_araddr;
    logic [7:0]            burst_arlen;
    logic [31:0]           burst_bytes_calc;
    logic [8:0]            burst_beats_calc;


    // =========================================================
    // Current Burst Registers
    // =========================================================

    logic [AXI_ADDR_W-1:0] burst_addr_reg;
    logic [7:0]            burst_arlen_reg;
    logic [31:0]           burst_bytes_reg;
    logic [8:0]            burst_beats_reg;


    // =========================================================
    // Beat Counter
    // =========================================================

    logic [8:0] beats_received;


    // =========================================================
    // Internal Control Signals
    // =========================================================

    logic cmd_fire;
    logic ar_fire;
    logic r_fire;

    logic rresp_ok;
    logic expected_last;

    logic burst_done;
    logic transfer_done;


    // =========================================================
    // Handshake Signals
    // =========================================================

    assign cmd_fire =
        cmd_valid &&
        cmd_ready;

    assign ar_fire =
        m_axi_arvalid &&
        m_axi_arready;

    assign r_fire =
        m_axi_rvalid &&
        m_axi_rready;


    // =========================================================
    // DMA Status / Command Interface
    // =========================================================

    assign cmd_ready =
        (state == IDLE);

    assign busy =
        (state != IDLE);

    assign done =
        (state == COMPLETE);


    // =========================================================
    // Burst Manager
    // =========================================================

    axi_read_dma_burst_manager #(
        .AXI_ADDR_W (AXI_ADDR_W),
        .AXI_DATA_W (AXI_DATA_W)
    ) u_burst_manager (
        .current_axi_addr (current_axi_addr),
        .bytes_remaining  (bytes_remaining),

        .araddr            (burst_araddr),
        .arlen             (burst_arlen),
        .burst_bytes       (burst_bytes_calc),
        .burst_beats       (burst_beats_calc)
    );


    // =========================================================
    // State Register
    // =========================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;

    end


    // =========================================================
    // Next-State Logic
    // =========================================================

    always_comb begin

        next_state = state;

        case (state)

            // -------------------------------------------------
            // Wait for a new DMA command
            // -------------------------------------------------

            IDLE: begin

                if (cmd_fire)
                    next_state = PREPARE_BURST;

            end


            // -------------------------------------------------
            // Capture Burst Manager outputs
            // -------------------------------------------------

            PREPARE_BURST: begin

                next_state = SEND_AR;

            end


            // -------------------------------------------------
            // Wait for AXI Read Address handshake
            // -------------------------------------------------

            SEND_AR: begin

                if (ar_fire)
                    next_state = RECV_R;

            end


            // -------------------------------------------------
            // Receive current AXI read burst
            // -------------------------------------------------

            RECV_R: begin

                if (burst_done) begin

                    if (transfer_done)
                        next_state = COMPLETE;
                    else
                        next_state = PREPARE_BURST;

                end

            end


            // -------------------------------------------------
            // Generate one-cycle completion indication
            // -------------------------------------------------

            COMPLETE: begin

                next_state = IDLE;

            end


            // -------------------------------------------------
            // Illegal state recovery
            // -------------------------------------------------

            default: begin

                next_state = IDLE;

            end

        endcase

    end


    // =========================================================
    // DMA Address / Remaining Byte Registers
    // =========================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            current_axi_addr <= '0;
            bytes_remaining  <= '0;

        end
        else begin

            // New DMA command
            if (cmd_fire) begin

                current_axi_addr <= cmd_axi_addr;
                bytes_remaining  <= cmd_len_bytes;

            end

            // Current burst completed
            else if (burst_done) begin

                current_axi_addr <=
                    current_axi_addr +
                    burst_bytes_reg;

                bytes_remaining <=
                    bytes_remaining -
                    burst_bytes_reg;

            end

        end

    end


    // =========================================================
    // SRAM Write Pointer
    // =========================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            sram_wr_ptr <= '0;

        end
        else begin

            // Initial SRAM destination address
            if (cmd_fire) begin

                sram_wr_ptr <= cmd_sram_addr;

            end

            // Advance one SRAM word for every accepted AXI beat
            else if (r_fire) begin

                sram_wr_ptr <=
                    sram_wr_ptr + 1'b1;

            end

        end

    end


    // =========================================================
    // Capture Current Burst
    // =========================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            burst_addr_reg  <= '0;
            burst_arlen_reg <= '0;
            burst_bytes_reg <= '0;
            burst_beats_reg <= '0;

        end
        else begin

            if (state == PREPARE_BURST) begin

                burst_addr_reg  <= burst_araddr;
                burst_arlen_reg <= burst_arlen;
                burst_bytes_reg <= burst_bytes_calc;
                burst_beats_reg <= burst_beats_calc;

            end

        end

    end


    // =========================================================
    // AXI Read Address Channel
    // =========================================================

    assign m_axi_araddr =
        burst_addr_reg;

    assign m_axi_arlen =
        burst_arlen_reg;

    assign m_axi_arsize =
        AXI_ARSIZE;

    assign m_axi_arburst =
        AXI_BURST_INCR;

    assign m_axi_arvalid =
        (state == SEND_AR);


    // =========================================================
    // AXI Read Data Channel
    // =========================================================

    assign m_axi_rready =
        (state == RECV_R);

    assign rresp_ok =
        (m_axi_rresp == AXI_RESP_OKAY);


    // =========================================================
    // Beat Counter
    // =========================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            beats_received <= '0;

        end
        else begin

            if (state == PREPARE_BURST) begin

                beats_received <= '0;

            end
            else if (r_fire) begin

                beats_received <=
                    beats_received + 1'b1;

            end

        end

    end


    // =========================================================
    // Expected Last Beat
    // =========================================================

    assign expected_last =
        (beats_received ==
         (burst_beats_reg - 1'b1));


    // =========================================================
    // Burst Completion
    // =========================================================

    assign burst_done =
        r_fire &&
        expected_last;


    // =========================================================
    // Full DMA Transfer Completion
    // =========================================================

    assign transfer_done =
        burst_done &&
        (bytes_remaining == burst_bytes_reg);


    // =========================================================
    // SRAM Write Interface
    // =========================================================

    assign sram_we =
        r_fire &&
        rresp_ok;

    assign sram_waddr =
        sram_wr_ptr;

    assign sram_wdata =
        m_axi_rdata;


    // =========================================================
    // Sticky Error Register
    // =========================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            error <= 1'b0;

        end
        else begin

            // Clear error when accepting a new command
            if (cmd_fire) begin

                error <= 1'b0;

            end
            else if (r_fire) begin

                // Read response error
                if (!rresp_ok)
                    error <= 1'b1;

                // RLAST arrived early or was missing
                if (expected_last ^ m_axi_rlast)
                    error <= 1'b1;

            end

        end

    end

endmodule