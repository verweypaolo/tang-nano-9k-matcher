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
    output reg wrongMsgSide,
    output reg matchLoopOverrunError
);


localparam MSG_TYPE_NEW_ORDER = 8'h01;
localparam MSG_SIDE_BUY = 8'h00;
localparam MSG_SIDE_SELL = 8'h01;


// message_rx outputs
wire messageReady;
wire sentinelError, timeOutError, checksumError;
wire [7:0] msgType, side;
wire [15:0] orderID, price, quantity;

// bid book outputs
wire simultaneousOpErrorBid, insertFullErrorBid, removeEmptyErrorBid, reduceEmptyErrorBid, overReduceErrorBid;
wire [N-1:0] validBidBook;
wire [16*N-1:0] orderIDBidBook, priceBidBook, quantityBidBook, seqNumBidBook;

// ask book outputs
wire simultaneousOpErrorAsk, insertFullErrorAsk, removeEmptyErrorAsk, reduceEmptyErrorAsk, overReduceErrorAsk;
wire [N-1:0] validAskBook;
wire [16*N-1:0] orderIDAskBook, priceAskBook, quantityAskBook, seqNumAskBook;

// helper wires for tracking book state
wire oppositeValid0 = (side == MSG_SIDE_BUY) ? validAskBook[0] : validBidBook[0];
wire [15:0] oppositePrice0 = (side == MSG_SIDE_BUY) ? priceAskBook[15:0] : priceBidBook[15:0];
wire [15:0] oppositeQty0 = (side == MSG_SIDE_BUY) ? quantityAskBook[15:0] : quantityBidBook[15:0];
wire crosses = (side == MSG_SIDE_BUY) ? (price >= oppositePrice0) : (price <= oppositePrice0);

// bid/ask book triggers
reg insertValidBid, removeValidBid;
reg insertValidAsk, removeValidAsk;
reg reduceValidBid, reduceValidAsk;
reg [15:0] reduceAmountBid, reduceAmountAsk;

reg [15:0] globalSeqNum; // increment once per accepted NEW_ORDER
reg [15:0] remainingQuantity;
reg [3:0] matchLoopCount;

localparam MATCH_LOOP_MAX = N;

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
    .insertQuantity(remainingQuantity),
    .insertOrderID(orderID),
    .insertSeqNum(globalSeqNum),
    .removeValid(removeValidBid),
    .reduceValid(reduceValidBid),
    .reduceAmount(reduceAmountBid),
    .valid(validBidBook),
    .price(priceBidBook),
    .quantity(quantityBidBook),
    .orderID(orderIDBidBook),
    .seqNum(seqNumBidBook),
    .simultaneousOpError(simultaneousOpErrorBid),
    .insertFullError(insertFullErrorBid),
    .removeEmptyError(removeEmptyErrorBid),
    .reduceEmptyError(reduceEmptyErrorBid),
    .overReduceError(overReduceErrorBid)
);

order_book_side
#(
    .N(N),
    .DESCENDING(0)
) ask_book (
    .clk(clk),
    .insertValid(insertValidAsk),
    .insertPrice(price),
    .insertQuantity(remainingQuantity),
    .insertOrderID(orderID),
    .insertSeqNum(globalSeqNum),
    .removeValid(removeValidAsk),
    .reduceValid(reduceValidAsk),
    .reduceAmount(reduceAmountAsk),
    .valid(validAskBook),
    .price(priceAskBook),
    .quantity(quantityAskBook),
    .orderID(orderIDAskBook),
    .seqNum(seqNumAskBook),
    .simultaneousOpError(simultaneousOpErrorAsk),
    .insertFullError(insertFullErrorAsk),
    .removeEmptyError(removeEmptyErrorAsk),
    .reduceEmptyError(reduceEmptyErrorAsk),
    .overReduceError(overReduceErrorAsk)
);


// messageReady edge
reg messageReadyPrev;
wire messageReadyEdge = messageReady & !messageReadyPrev;

reg [3:0] meState;

localparam ME_STATE_IDLE = 0;
localparam ME_STATE_DECIDE = 1;
localparam ME_STATE_MATCH_LOOP = 2;
localparam ME_STATE_MATCH_LOOP_WAIT = 3;
localparam ME_STATE_REST = 4;
localparam ME_STATE_REST_WAIT = 5;
localparam ME_STATE_REST_CONFIRM = 6;


initial begin
    insertValidBid = 0;
    removeValidBid = 0;
    insertValidAsk = 0;
    removeValidAsk = 0;
    reduceValidBid = 0;
    reduceValidAsk = 0;
    reduceAmountBid = 0;
    reduceAmountAsk = 0;

    remainingQuantity = 0;
    matchLoopCount = 0;
    globalSeqNum = 0;
    messageReadyPrev = 0;
    meState = 0;

    wrongMsgSide = 0;
    wrongMsgType = 0;
    matchLoopOverrunError = 0;
end

always @(posedge clk) begin
    messageReadyPrev <= messageReady;
end

always @(posedge clk) begin
    // default: all pulses low unless explicitly asserted below
    insertValidBid <= 0;
    removeValidBid <= 0;
    insertValidAsk <= 0;
    removeValidAsk <= 0;
    reduceValidBid <= 0;
    reduceValidAsk <= 0;

    case (meState)
        ME_STATE_IDLE: begin
            if (messageReadyEdge) begin
                orderFilled <= 0;
                orderResting <= 0;
                orderRejected <= 0;
                wrongMsgType <= 0;
                wrongMsgSide <= 0;
                matchLoopOverrunError <= 0;
                meState <= ME_STATE_DECIDE;
            end
        end
        ME_STATE_DECIDE: begin
            if (msgType != MSG_TYPE_NEW_ORDER) begin
                wrongMsgType <= 1;
                meState <= ME_STATE_IDLE;
            end else if (side == MSG_SIDE_BUY || side == MSG_SIDE_SELL) begin
                remainingQuantity <= quantity;
                matchLoopCount <= 0;
                if (oppositeValid0 && crosses) begin
                    meState <= ME_STATE_MATCH_LOOP; // match
                end else begin
                    meState <= ME_STATE_REST; // no match, try to rest
                end
            end else begin
                wrongMsgSide <= 1;
                meState <= ME_STATE_IDLE;
            end
        end
        ME_STATE_MATCH_LOOP: begin
            if (oppositeValid0 && crosses) begin // if price ok and valid order to match against exists
                if (matchLoopCount == MATCH_LOOP_MAX) begin
                    matchLoopOverrunError <= 1;
                    meState <= ME_STATE_IDLE;
                end else if (oppositeQty0 < remainingQuantity) begin
                    if (side == MSG_SIDE_BUY) begin
                        removeValidAsk <= 1; // fully consume order from opposite book
                    end else begin
                        removeValidBid <= 1;
                    end
                    remainingQuantity <= remainingQuantity - oppositeQty0; // must do manual, quantity will not update until next cycle
                    matchLoopCount <= matchLoopCount + 1;
                    meState <= ME_STATE_MATCH_LOOP_WAIT;
                end else if (oppositeQty0 == remainingQuantity) begin
                    // exact match, pop and were done (back to idle)
                    if (side == MSG_SIDE_BUY) begin
                        removeValidAsk <= 1;
                    end else begin
                        removeValidBid <= 1;
                    end
                    remainingQuantity <= 0;
                    orderFilled <= 1;
                    globalSeqNum <= globalSeqNum + 1;
                    meState <= ME_STATE_IDLE;
                end else begin
                    // best order now has more quantity available, reduce
                    if (side == MSG_SIDE_BUY) begin
                        reduceValidAsk <= 1;
                        reduceAmountAsk <= remainingQuantity;
                    end else begin
                        reduceValidBid <= 1;
                        reduceAmountBid <= remainingQuantity;
                    end
                    remainingQuantity <= 0;
                    orderFilled <= 1;
                    globalSeqNum <= globalSeqNum + 1;
                    meState <= ME_STATE_IDLE;
                end    
            end else begin
                // price no longer ok, or no more valid orders to match against, rest order
                meState <= ME_STATE_REST;
            end
        end
        ME_STATE_MATCH_LOOP_WAIT: begin
            // needed to give one clock cycle breathing room for order book instances to update after match loop
            // actions. Otherwise the cycle after an action in match loop will read stale values pre update
            meState <= ME_STATE_MATCH_LOOP;
        end
        ME_STATE_REST: begin
            if (side == MSG_SIDE_BUY) begin
                insertValidBid <= 1;
            end else begin
                insertValidAsk <= 1;
            end
            meState <= ME_STATE_REST_WAIT; // need this state as insertion errors only asserted on next cycle
        end
        ME_STATE_REST_WAIT: begin
            // Need this cycle wait to allow the order book instances to update the error flags read in the 
            // REST_CONFIRM state, otherwise pre update stale values read.
            meState <= ME_STATE_REST_CONFIRM;
        end
        ME_STATE_REST_CONFIRM: begin
            if ((side == MSG_SIDE_BUY && insertFullErrorBid) || (side == MSG_SIDE_SELL && insertFullErrorAsk)) begin
                orderRejected <= 1;
            end else begin
                orderResting <= 1;
                globalSeqNum <= globalSeqNum + 1;
            end
            meState <= ME_STATE_IDLE;
        end
    endcase
end

endmodule
