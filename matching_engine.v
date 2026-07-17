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
    input uart_rx_line
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



endmodule
