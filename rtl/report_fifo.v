`default_nettype none

// Synchronous FIFO for buffering execution reports between the matching
// engine and UART TX. Replaces the 1-deep pending-report register that
// was getting overwritten under burst match conditions.
//
// - wr_en/rd_en are expected as single-cycle pulses from the driving FSMs.

module report_fifo #(
    parameter DATA_WIDTH = 64,  // msgType(8) + orderID(16) + outcome(8) + price(16) + quantity(16)
    parameter DEPTH      = 8,
    parameter PTR_WIDTH  = $clog2(DEPTH)
) (
    input clk,
    input rst_n,

    input wr_en,
    input [DATA_WIDTH-1:0] wr_data,

    input rd_en,
    output reg [DATA_WIDTH-1:0] rd_data,

    output full,
    output empty,

    input clear_full,
    output reg full_latched
);

    reg [DEPTH*DATA_WIDTH-1:0] mem_flat;

    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [PTR_WIDTH:0] count;   // needs DEPTH+1 states (0..DEPTH), one bit wider than PTR_WIDTH

    initial begin
        wr_ptr = 0;
        rd_ptr = 0;
        count  = 0;
        rd_data = 0;
        full_latched = 0;
        mem_flat = 0;
    end

    assign full  = (count == DEPTH);
    assign empty = (count == 0);

    wire do_write = wr_en && !full;
    wire do_read  = rd_en && !empty;

    // Write pointer + slot write via indexed part-select
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
        end else if (do_write) begin
            mem_flat[wr_ptr*DATA_WIDTH +: DATA_WIDTH] <= wr_data;
            wr_ptr <= wr_ptr + 1;
        end
    end

    // Read pointer + registered read data via indexed part-select
    // (still 1-cycle read latency, registered on the clock edge)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr  <= 0;
            rd_data <= 0;
        end else if (do_read) begin
            rd_data <= mem_flat[rd_ptr*DATA_WIDTH +: DATA_WIDTH];
            rd_ptr  <= rd_ptr + 1;
        end
    end

    // Occupancy count — handles simultaneous read+write (net change = 0)
    // explicitly rather than relying on the two increments/decrements
    // cancelling out incidentally.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= 0;
        end else begin
            case ({do_write, do_read})
                2'b10:   count <= count + 1;
                2'b01:   count <= count - 1;
                default: count <= count; // 2'b00 or 2'b11
            endcase
        end
    end

    // Sticky full flag for LED debug — set on first full event, held
    // until explicitly cleared.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            full_latched <= 1'b0;
        end else if (clear_full) begin
            full_latched <= 1'b0;
        end else if (full) begin
            full_latched <= 1'b1;
        end
    end

endmodule
