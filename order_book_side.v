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
    output reg [7:0] valid, // packed vectors
    output reg [16*N-1:0] price,
    output reg [16*N-1:0] quantity,
    output reg [16*N-1:0] orderID,
    output reg [16*N-1:0] seqNum,

    output reg simultaneousOpError,
    output reg insertFullError,
    output reg removeEmptyError
);

// insertion edge
reg insertValidPrev;
wire insertValidEdge = insertValid & !insertValidPrev;

// removal edge
reg removeValidPrev;
wire removeValidEdge = removeValid & !removeValidPrev;

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
            if (!valid[j] || (DESCENDING ? (insertPrice > price[j*16 +: 16]) : (insertPrice < price[j*16 +: 16]))) begin
                insertIndex = j;
            end
        end
    end
end

// initialization
integer i;
initial begin
    insertValidPrev = 0;
    removeValidPrev = 0;
    valid = 0;
    simultaneousOpError = 0;
    insertFullError = 0;
    removeEmptyError = 0;
    price = 0;
    quantity = 0;
    orderID = 0;
    seqNum = 0;
end

always @(posedge clk) begin
    insertValidPrev <= insertValid;
    removeValidPrev <= removeValid;
end

always @(posedge clk) begin
    if (insertValidEdge && removeValidEdge) begin
        simultaneousOpError <= 1;
        // don't do anything else: safest, though can design a tie break here
    end
    else if (insertValidEdge) begin
        simultaneousOpError <= 0;
        insertFullError <= 0;
        removeEmptyError <= 0;

        if (bookEmpty) begin
            valid[0] <= 1;
            price[15:0] <= insertPrice;
            quantity[15:0] <= insertQuantity;
            orderID[15:0] <= insertOrderID;
            seqNum[15:0] <= insertSeqNum;
        end else if (bookFull) begin
            insertFullError <= 1;
        end else begin // normal case
            // combinational logic, everything happens at once and is updated on next clock cyle => no timing error with assigning
            // at the insert index and also having to shift the old value!
            for (i = 0; i < N; i = i + 1) begin
                if (i < insertIndex) begin // works for both bid and ask due to insertIndex construction (DESCENDING)
                    // do nothing, entries have higher price (bid) or lower price (ask)
                end else if (i == insertIndex) begin
                    valid[i] <= 1;
                    price[i*16 +: 16] <= insertPrice;
                    quantity[i*16 +: 16] <= insertQuantity;
                    orderID[i*16 +: 16] <= insertOrderID;
                    seqNum[i*16 +: 16] <= insertSeqNum;
                end else if (i > 0) begin // add i > 0 to prevent yosys warnings about out-of-bounds indexes in the speculatively synthesized hardware
                    // increase index by 1 for everything below the insertIndex
                    valid[i] <= valid[i-1];
                    price[i*16 +: 16] <= price[(i-1)*16 +: 16];
                    quantity[i*16 +: 16] <= quantity[(i-1)*16 +: 16];
                    orderID[i*16 +: 16] <= orderID[(i-1)*16 +: 16];
                    seqNum[i*16 +: 16] <= seqNum[(i-1)*16 +: 16];
                    // note: book cannot be full here, so at least one empty slot exists to shift empty/garbage entries into
                end
            end
        end
    end else if (removeValidEdge) begin
        simultaneousOpError <= 0;
        insertFullError <= 0;
        removeEmptyError <= 0;

        if (bookEmpty) begin
            removeEmptyError <= 1;
        end else begin // non-empty book
            for (i = 0; i < N - 1; i = i + 1) begin
                valid[i] <= valid[i+1];
                price[i*16 +: 16] <= price[(i+1)*16 +: 16];
                quantity[i*16 +: 16] <= quantity[(i+1)*16 +: 16];
                orderID[i*16 +: 16] <= orderID[(i+1)*16 +: 16];
                seqNum[i*16 +: 16] <= seqNum[(i+1)*16 +: 16];
            end
            valid[N-1] <= 0; // last row always has to be invalidated
        end
    end
end


endmodule
