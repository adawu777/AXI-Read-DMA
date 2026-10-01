module axi_read_dma_fsm (
    input  logic clk,
    input  logic rst_n,

    // Command interface
    input  logic cmd_valid,
    output logic cmd_ready,

    // AXI Read Address handshake
    input  logic m_axi_arready,
    output logic m_axi_arvalid,

    // Read burst completion
    input  logic burst_done,

    // Transfer completion information
    input  logic transfer_done,

    // Status
    output logic busy,
    output logic done
);

    // ---------------------------------------------------------
    // FSM state definition
    // ---------------------------------------------------------

    typedef enum logic [2:0] {
        IDLE,
        PREPARE_BURST,
        SEND_AR,
        RECV_R,
        COMPLETE
    } state_t;

    state_t state;
    state_t next_state;


    // ---------------------------------------------------------
    // Internal handshake signals
    // ---------------------------------------------------------

    logic cmd_fire;
    logic ar_fire;


    assign cmd_fire =
        cmd_valid &&
        cmd_ready;

    assign ar_fire =
        m_axi_arvalid &&
        m_axi_arready;


    // ---------------------------------------------------------
    // State register
    // ---------------------------------------------------------

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;

    end


    // ---------------------------------------------------------
    // Next-state logic
    // ---------------------------------------------------------

    always_comb begin

        // Default:
        // remain in the current state
        next_state = state;

        case (state)

            // -------------------------------------------------
            // IDLE
            //
            // Wait for a new DMA command.
            // -------------------------------------------------

            IDLE: begin

                if (cmd_fire)
                    next_state = PREPARE_BURST;

            end


            // -------------------------------------------------
            // PREPARE_BURST
            //
            // Burst Manager calculates:
            //
            //   ARADDR
            //   ARLEN
            //   burst_bytes
            //   burst_beats
            //
            // The calculation is combinational, so one FSM
            // cycle is used here to prepare the burst.
            // -------------------------------------------------

            PREPARE_BURST: begin

                next_state = SEND_AR;

            end


            // -------------------------------------------------
            // SEND_AR
            //
            // Assert ARVALID and wait for ARREADY.
            //
            // Do not leave this state until the AXI
            // Read Address handshake occurs.
            // -------------------------------------------------

            SEND_AR: begin

                if (ar_fire)
                    next_state = RECV_R;

            end


            // -------------------------------------------------
            // RECV_R
            //
            // Receive AXI read data beats.
            //
            // burst_done:
            //   The current burst has received all expected
            //   beats.
            //
            // transfer_done:
            //   The current burst is also the final burst
            //   of the entire DMA command.
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
            // COMPLETE
            //
            // Generate a one-cycle done pulse.
            // -------------------------------------------------

            COMPLETE: begin

                next_state = IDLE;

            end


            // -------------------------------------------------
            // Illegal / unknown state recovery
            // -------------------------------------------------

            default: begin

                next_state = IDLE;

            end

        endcase

    end


    // ---------------------------------------------------------
    // Output logic
    // ---------------------------------------------------------

    always_comb begin

        // Default outputs
        cmd_ready     = 1'b0;
        m_axi_arvalid = 1'b0;
        busy          = 1'b1;
        done          = 1'b0;


        case (state)

            IDLE: begin

                cmd_ready = 1'b1;
                busy      = 1'b0;

            end


            PREPARE_BURST: begin

                // Burst Manager prepares the next burst.
                busy = 1'b1;

            end


            SEND_AR: begin

                // Hold ARVALID high until ARREADY handshake.
                m_axi_arvalid = 1'b1;
                busy          = 1'b1;

            end


            RECV_R: begin

                busy = 1'b1;

            end


            COMPLETE: begin

                busy = 1'b1;
                done = 1'b1;

            end


            default: begin

                cmd_ready     = 1'b0;
                m_axi_arvalid = 1'b0;
                busy          = 1'b0;
                done          = 1'b0;

            end

        endcase

    end

endmodule