`default_nettype none

module order_book_side
#(
    parameter N = 8
)
(
    input clk,
    input insertValid, // insert a new order on pulse
    input [15:0] insertPrice,
    input [15:0] insertQuantity,
    input [15:0] insertOrderID,
    input [15:0] insertSeqNum,

    input removeValid, // remove slot 0 on pulse

    // order book regs
    output reg [7:0] valid,
    output reg [15:0] price [0:N-1],
    output reg [15:0] quantity [0:N-1],
    output reg [15:0] orderID [0:N-1],
    output reg [15:0] seqNum [0:N-1]
);

endmodule


