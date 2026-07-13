`default_nettype none

module order_book_side
#(
    parameter N = 8,
    parameter DESCENDING = 1 // 1 = bid, highest price on top i.e. descending on price
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

// insertion index
reg [3:0] insertIndex; // target index
integer j;

always @(*) begin // runs combinationally! Continuously provides insertion index
    insertIndex = N;
    for (j = 0; j < N; j = j + 1) begin
        if (insertIndex == N) begin
            if (!valid[j] || (DESCENDING ? (insertPrice > price[j]) : (insertPrice < price[j]))) begin
                insertIndex = j;
            end
        end
    end
end

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
            // combinational logic, everything happens at once and is updated on next clock cyle => no timing error with assigning
            // at the insert index and also having to shift the old value!
            for (i = 0; i < N; i = i + 1) begin
                if (i < insertIndex) begin // works for both bid and ask due to insertIndex construction (DESCENDING)
                    // do nothing, entries have higher price (bid) or lower price (ask)
                end
                else if (i == insertIndex) begin
                    valid[i] <= 1;
                    price[i] <= insertPrice;
                    quantity[i] <= insertQuantity;
                    orderID[i] <= insertOrderID;
                    seqNum[i] <= insertSeqNum;
                end
                else begin
                    // increase index by 1 for everything below the insertIndex
                    valid[i]    <= valid[i-1];
                    price[i]    <= price[i-1];
                    quantity[i] <= quantity[i-1];
                    orderID[i]  <= orderID[i-1];
                    seqNum[i]   <= seqNum[i-1];
                    // note: book cannot be full here, so at least one empty slot exists to shift empty/garbage entries into
                end
            end
        end
    end
end


endmodule
