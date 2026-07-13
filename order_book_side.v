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
    output reg [7:0] valid, // packed vector
    output reg [15:0] price [0:N-1],
    output reg [15:0] quantity [0:N-1],
    output reg [15:0] orderID [0:N-1],
    output reg [15:0] seqNum [0:N-1]
);

// insertion edge
reg insertValidPrev;
wire insertValidEdge = insertValid & !insertValidPrev;

// edge cases
wire bookEmpty = (valid == 8'b0);
wire bookFull = &valid; // AND reduction

// initialization
integer i;
initial begin
    insertValidPrev = 0;
    valid = 0;
    for (i = 0; i < N; i = i + 1) begin
        price[i] = 0;
        quantity[i] = 0;
        orderID[i] = 0;
        seqNum[i] = 0;
    end
end

always @(posedge clk) begin
    insertValidPrev <= insertValid;
end

always @(posedge clk) begin
    if (insertValidEdge) begin
        if (bookEmpty) begin
            valid[0] <= 1;
            price[0] <= insertPrice;
            quantity[0] <= insertQuantity;
            orderID[0] <= insertOrderID;
            seqNum[0] <= insertSeqNum;
        end
        else if (bookFull) begin
        end
        else begin // normal case
        end
    end
end


endmodule


