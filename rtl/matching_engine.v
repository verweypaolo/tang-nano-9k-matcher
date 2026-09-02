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
    output uart_tx_line,

    output reg orderFilled,
    output reg orderResting,
    output reg orderRejected,

    output reg wrongMsgType,
    output reg wrongMsgSide,
    output reg matchLoopOverrunError,
    
    output reg sentinelErrorLatched,
    output reg timeOutErrorLatched,
    output reg checksumErrorLatched
);


localparam MSG_TYPE_NEW_ORDER = 8'h01;
localparam MSG_SIDE_BUY = 8'h00;
localparam MSG_SIDE_SELL = 8'h01;

localparam RPT_FILLED = 8'h01;
localparam RPT_RESTING = 8'h02;
localparam RPT_REJECTED = 8'h03;
localparam RPT_INVALID = 8'h04; // malformed message (bad msgType or bad side)

localparam RPT_MESSAGE_TYPE_EXECUTION = 8'h01; // indicates type of transmitted report (execution)

localparam DATA_WIDTH = 64;

// message_rx outputs
wire messageReady;
wire sentinelError, timeOutError, checksumError;
wire [7:0] msgType, side;
wire [15:0] orderID, price, quantity;

// message_tx inputs
reg sendMessageValid;
reg [7:0] msgTypeOut, outcomeOut;
reg [15:0] orderIDOut, priceOut, quantityOut;

// message_tx outputs
wire messageSent;
wire txBusy;
wire sendWhileBusyError;

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

// FIFO inputs
reg rst_n, wr_en, rd_en, clear_full;
reg [DATA_WIDTH-1:0] wr_data;

// FIFO outputs
wire full, empty, full_latched;
wire [DATA_WIDTH-1:0] rd_data;

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

message_tx
#(
    .SENTINEL(SENTINEL),
    .BAUD_DIVISOR(BAUD_DIVISOR),
    .ACC_INCREMENT(ACC_INCREMENT),
    .ACC_MODULUS(ACC_MODULUS)
) msg_tx_inst (
    .clk(clk),
    .uart_tx_line(uart_tx_line),
    .sendMessageValid(sendMessageValid),
    .msgTypeIn(msgTypeOut),
    .orderIDIn(orderIDOut),
    .outcomeIn(outcomeOut),
    .priceIn(priceOut),
    .quantityIn(quantityOut),
    .messageSent(messageSent),
    .txBusy(txBusy),
    .sendWhileBusyError(sendWhileBusyError)
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

report_fifo
#(
    .DATA_WIDTH(DATA_WIDTH)
) report_queue (
    .clk(clk),
    .rst_n(rst_n),
    .wr_en(wr_en),
    .wr_data(wr_data),
    .rd_en(rd_en),
    .rd_data(rd_data),
    .full(full),
    .empty(empty),
    .clear_full(clear_full),
    .full_latched(full_latched)
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
localparam ME_STATE_MATCH_DONE_WAIT = 7;

reg [1:0] drainState;

localparam DRAIN_STATE_IDLE = 0;
localparam DRAIN_STATE_WAIT = 1;
localparam DRAIN_STATE_CAPTURE = 2;


initial begin
    insertValidBid = 0;
    removeValidBid = 0;
    insertValidAsk = 0;
    removeValidAsk = 0;
    reduceValidBid = 0;
    reduceValidAsk = 0;
    reduceAmountBid = 0;
    reduceAmountAsk = 0;

    sendMessageValid = 0;
    msgTypeOut = 0;
    orderIDOut = 0;
    outcomeOut = 0;
    priceOut = 0;
    quantityOut = 0;

    remainingQuantity = 0;
    matchLoopCount = 0;
    globalSeqNum = 0;
    messageReadyPrev = 0;
    meState = 0;

    wrongMsgSide = 0;
    wrongMsgType = 0;
    matchLoopOverrunError = 0;

    orderFilled = 0;
    orderResting = 0;
    orderRejected = 0;

    drainState = 0;

    rst_n = 1; // held high
    wr_en = 0;
    rd_en = 0;
    clear_full = 0;
    wr_data = 0;

    sentinelErrorLatched = 0;
    timeOutErrorLatched  = 0;
    checksumErrorLatched = 0;
end

always @(posedge clk) begin
    messageReadyPrev <= messageReady;
end

always @(posedge clk) begin
    if (sentinelError) sentinelErrorLatched <= 1;
end

always @(posedge clk) begin
    if (timeOutError) timeOutErrorLatched <= 1;
end

always @(posedge clk) begin
    if (checksumError) checksumErrorLatched <= 1;
end

always @(posedge clk) begin
    // default: all pulses low unless explicitly asserted below
    insertValidBid <= 0;
    removeValidBid <= 0;
    insertValidAsk <= 0;
    removeValidAsk <= 0;
    reduceValidBid <= 0;
    reduceValidAsk <= 0;

    wr_en <= 0;

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
                // write to queue
                wr_en <= 1;
                wr_data <= {RPT_MESSAGE_TYPE_EXECUTION, orderID, RPT_INVALID, price, quantity};
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
                // write to queue
                wr_en <= 1;
                wr_data <= {RPT_MESSAGE_TYPE_EXECUTION, orderID, RPT_INVALID, price, quantity};
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
                    globalSeqNum <= globalSeqNum + 1;
                    meState <= ME_STATE_MATCH_DONE_WAIT;
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
                    globalSeqNum <= globalSeqNum + 1;
                    meState <= ME_STATE_MATCH_DONE_WAIT;
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
        ME_STATE_MATCH_DONE_WAIT: begin
            // same reason as other waiting states: need an extra cycle to allow the order book state to update,
            // otherwise orderFilled is asserted one cycle BEFORE the book updates.
            orderFilled <= 1;
            meState <= ME_STATE_IDLE;
            // write to queue
            wr_en <= 1;
            wr_data <= {RPT_MESSAGE_TYPE_EXECUTION, orderID, RPT_FILLED, price, quantity};
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
                // write to queue
                wr_en <= 1;
                wr_data <= {RPT_MESSAGE_TYPE_EXECUTION, orderID, RPT_REJECTED, price, quantity};
            end else begin
                orderResting <= 1;
                globalSeqNum <= globalSeqNum + 1;
                // write to queue
                wr_en <= 1;
                wr_data <= {RPT_MESSAGE_TYPE_EXECUTION, orderID, RPT_RESTING, price, remainingQuantity};
            end
            meState <= ME_STATE_IDLE;
        end
    endcase
end

always @(posedge clk) begin
    sendMessageValid <= 0;
    rd_en <= 0;

    case(drainState)
        DRAIN_STATE_IDLE: begin
            if(!empty && !txBusy) begin
                rd_en <= 1;
                drainState <= DRAIN_STATE_WAIT;
            end
        end
        DRAIN_STATE_WAIT:begin
            // need to wait for FIFO to put data in rd_data, takes 2 edges from rd_en in IDLE state above
            drainState <= DRAIN_STATE_CAPTURE;
        end
        DRAIN_STATE_CAPTURE: begin
            msgTypeOut  <= rd_data[63:56];
            orderIDOut  <= rd_data[55:40];
            outcomeOut  <= rd_data[39:32];
            priceOut    <= rd_data[31:16];
            quantityOut <= rd_data[15:0];

            sendMessageValid <= 1;
            drainState <= DRAIN_STATE_IDLE;
        end
    endcase
end

endmodule
