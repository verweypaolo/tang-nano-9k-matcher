`default_nettype none

module matching_engine
#(
    parameter SENTINEL = 8'hAA,
    parameter BAUD_DIVISOR = 234,
    parameter ACC_INCREMENT = 3,
    parameter ACC_MODULUS = 8,

    parameter N = 8
)
(
    input clk,
    input uart_rx_line,

    output reg orderFilled,
    output reg orderResting,
    output reg orderRejected,

    output reg wrongMsgType,
    output reg wrongMsgSide
);


// message_rx outputs
wire messageReady;
wire sentinelError, timeOutError, checksumError;
wire [7:0] msgType, side;
wire [15:0] orderID, price, quantity;

// bid book outputs
wire simultaneousOpErrorBid, insertFullErrorBid, removeEmptyErrorBid;
wire [N-1:0] validBidBook;
wire [16*N-1:0] orderIDBidBook, priceBidBook, quantityBidBook, seqNumBidBook;

// ask book outputs
wire simultaneousOpErrorAsk, insertFullErrorAsk, removeEmptyErrorAsk;
wire [N-1:0] validAskBook;
wire [16*N-1:0] orderIDAskBook, priceAskBook, quantityAskBook, seqNumAskBook;

// bid/ask book triggers
reg insertValidBid, removeValidBid;
reg insertValidAsk, removeValidAsk;

reg [15:0] globalSeqNum; // increment once per accepted NEW_ORDER


// instantiate submodules
message_rx
#(
    .SENTINEL(SENTINEL),
    .BAUD_DIVISOR(BAUD_DIVISOR),
    .ACC_INCREMENT(ACC_INCREMENT),
    .ACC_MODULUS(ACC_MODULUS)
) msg_rx_inst (
    .clk(clk),
    .uart_rx(uart_rx_line),
    .messageReady(messageReady),
    .sentinelError(sentinelError),
    .timeOutError(timeOutError),
    .checksumError(checksumError),
    .msgType(msgType),
    .orderID(orderID),
    .side(side),
    .price(price),
    .quantity(quantity)
);

order_book_side
#(
    .N(N),
    .DESCENDING(1)
) bid_book (
    .clk(clk),
    .insertValid(insertValidBid),
    .insertPrice(price),
    .insertQuantity(quantity),
    .insertOrderID(orderID),
    .insertSeqNum(globalSeqNum),
    .removeValid(removeValidBid),
    .valid(validBidBook),
    .price(priceBidBook),
    .quantity(quantityBidBook),
    .orderID(orderIDBidBook),
    .seqNum(seqNumBidBook),
    .simultaneousOpError(simultaneousOpErrorBid),
    .insertFullError(insertFullErrorBid),
    .removeEmptyError(removeEmptyErrorBid)
);

order_book_side
#(
    .N(N),
    .DESCENDING(0)
) ask_book (
    .clk(clk),
    .insertValid(insertValidAsk),
    .insertPrice(price),
    .insertQuantity(quantity),
    .insertOrderID(orderID),
    .insertSeqNum(globalSeqNum),
    .removeValid(removeValidAsk),
    .valid(validAskBook),
    .price(priceAskBook),
    .quantity(quantityAskBook),
    .orderID(orderIDAskBook),
    .seqNum(seqNumAskBook),
    .simultaneousOpError(simultaneousOpErrorAsk),
    .insertFullError(insertFullErrorAsk),
    .removeEmptyError(removeEmptyErrorAsk)
);


// messageReady edge
reg messageReadyPrev;
wire messageReadyEdge = messageReady & !messageReadyPrev;

reg [3:0] meState;

localparam ME_STATE_IDLE = 0;
localparam ME_STATE_DECIDE = 1;
localparam ME_STATE_MATCH_LOOP = 2;
localparam ME_STATE_REST = 3;
localparam ME_STATE_REJECT = 4;

localparam MSG_TYPE_NEW_ORDER = 8'h01;
localparam MSG_SIDE_BUY = 8'h00;
localparam MSG_SIDE_SELL = 8'h01;

initial begin
    insertValidBid = 0;
    removeValidBid = 0;
    insertValidAsk = 0;
    removeValidAsk = 0;
    globalSeqNum = 0;
    messageReadyPrev = 0;
    meState = 0;
end

always @(posedge clk) begin
    messageReadyPrev <= messageReady;
end

always @(posedge clk) begin
    case (meState)
        ME_STATE_IDLE: begin
            if (messageReadyEdge) begin
                orderFilled <= 0;
                orderResting <= 0;
                orderRejected <= 0;
                wrongMsgType <= 0;
                wrongMsgSide <= 0;
                meState <= ME_STATE_DECIDE;
            end
        end
        ME_STATE_DECIDE: begin
            if (msgType != MSG_TYPE_NEW_ORDER) begin
                wrongMsgType <= 1;
                meState <= ME_STATE_IDLE;
            end else if (side == MSG_SIDE_BUY) begin
                if (validAskBook[0] && price >= priceAskBook[15:0]) begin
                    meState <= ME_STATE_MATCH_LOOP; // match
                end else begin
                    meState <= ME_STATE_REST; // no match, try to rest
                end
            end else if (side == MSG_SIDE_SELL) begin
                if (validBidBook[0] && price <= priceBidBook[15:0]) begin
                    meState <= ME_STATE_MATCH_LOOP;
                end else begin
                    meState <= ME_STATE_REST;
                end
            end else begin
                wrongMsgSide <= 1;
                meState <= ME_STATE_IDLE;
            end
        end
    endcase
end

endmodule
