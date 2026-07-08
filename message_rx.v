`default_nettype none

module message_rx 
#(
    parameter SENTINEL = 8'hAA, // sentinel byte
    parameter BAUD_DIVISOR = 234
)
(
    input clk,
    input uart_rx
);

// must be confortable longer than minimum delay (BAUD_DIVISOR * 11)
localparam TIMEOUT_CYCLES = BAUD_DIVISOR * 11 * 20; // large number of cycles to account for transmission delay (serial jitter)

// instantiate these to connect the uart_rx outputs through
wire byteReady;
wire uartFrameError;
wire parityError;
wire [7:0] dataIn;

uart_rx #(
    .BAUD_DIVISOR(BAUD_DIVISOR)
) uart (
    .clk(clk),
    .uart_rx(uart_rx),
    .byteReady(byteReady),
    .uartFrameError(uartFrameError),
    .parityError(parityError),
    .dataIn(dataIn)
);


reg [3:0] msgState; // track state
reg [7:0] checksumAcc; // accumulate XOR of every received byte, check checksum at the end
reg byteCounter; // track which byte in states that have two bytes
reg [$clog2(TIMEOUT_CYCLES):0] byteWaitCounter;
reg messageReady;

// errors
reg sentinelError; // assert if sentinel doesn't match
reg timeOutError; // assert if more than TIMEOUT_CYCLES cycles before receiving a byte
reg checksumError; // assert if checksum doesn't match

// for byteReady edge
reg byteReadyPrev;
wire byteReadyEdge = byteReady & ~byteReadyPrev;

// store message content
reg [7:0] msgType;
reg [15:0] orderID;
reg [7:0] side; // 1 if sell
reg [15:0] price;
reg [15:0] quantity;

localparam MSG_STATE_IDLE = 0;
localparam MSG_STATE_SENTINEL  = 1; // validate sentinel byte
localparam MSG_STATE_MSG_TYPE  = 2; // capture msg type byte
localparam MSG_STATE_ORDER_ID  = 3; // capture 2 bytes (byte counter internal)
localparam MSG_STATE_SIDE      = 4; // capture side byte
localparam MSG_STATE_PRICE     = 5; // capture 2 bytes (byte counter internal)
localparam MSG_STATE_QUANTITY  = 6; // capture 2 bytes (byte counter internal)
localparam MSG_STATE_CHECKSUM  = 7; // capture + verify checksum byte

initial begin
    msgState = 0;
    checksumAcc = 0;
    byteCounter = 0;
    byteWaitCounter = 0;
    messageReady = 0;
    sentinelError = 0;
    timeOutError = 0;
    checksumError = 0;
    byteReadyPrev = 0;
    msgType = 0;
    orderID = 0;
    side = 0;
    price = 0;
    quantity = 0;
end

always @(posedge clk) begin
    byteReadyPrev <= byteReady; // for edge functionality
end

always @(posedge clk) begin
    case (msgState)
        MSG_STATE_IDLE: begin
            if (byteReadyEdge) begin
                checksumAcc <= 0;
                sentinelError <= 0;
                timeOutError <= 0;
                checksumError <= 0;
                messageReady <= 0;
                msgState <= MSG_STATE_SENTINEL;
            end
        end
        MSG_STATE_SENTINEL: begin
            if (dataIn == SENTINEL) begin
                checksumAcc <= checksumAcc ^ dataIn;
                byteWaitCounter <= 0;
                msgState <= MSG_STATE_MSG_TYPE;
            end else begin
                sentinelError <= 1;
                msgState <= MSG_STATE_IDLE; // move back to idle if wrong sentinel
            end
        end
        MSG_STATE_MSG_TYPE: begin
            if (byteReadyEdge) begin
                msgType <= dataIn;
                checksumAcc <= checksumAcc ^ dataIn;
                byteCounter <= 0;
                byteWaitCounter <= 0;
                msgState <= MSG_STATE_ORDER_ID;
            end else if (byteWaitCounter == TIMEOUT_CYCLES - 1) begin
                timeOutError <= 1;
                msgState <= MSG_STATE_IDLE;
            end else begin
                byteWaitCounter <= byteWaitCounter + 1;
            end
        end
        MSG_STATE_ORDER_ID: begin
            if (byteReadyEdge) begin
                orderID <= {orderID[7:0], dataIn}; // shift register for data, big endian
                checksumAcc <= checksumAcc ^ dataIn;
                byteWaitCounter <= 0;
                
                if (byteCounter == 1) begin
                    byteCounter <= 0;
                    msgState <= MSG_STATE_SIDE;
                end else begin
                    byteCounter <= byteCounter + 1;
                end
            end else if (byteWaitCounter == TIMEOUT_CYCLES - 1) begin
                timeOutError <= 1;
                msgState <= MSG_STATE_IDLE;
            end else begin
                byteWaitCounter <= byteWaitCounter + 1;
            end
        end
        MSG_STATE_SIDE: begin
            if (byteReadyEdge) begin
                side <= dataIn;
                checksumAcc <= checksumAcc ^ dataIn;
                byteCounter <= 0;
                byteWaitCounter <= 0;
                msgState <= MSG_STATE_PRICE;
            end else if (byteWaitCounter == TIMEOUT_CYCLES - 1) begin
                timeOutError <= 1;
                msgState <= MSG_STATE_IDLE;
            end else begin
                byteWaitCounter <= byteWaitCounter + 1;
            end
        end
        MSG_STATE_PRICE: begin
            if (byteReadyEdge) begin
                price <= {price[7:0], dataIn};
                checksumAcc <= checksumAcc ^ dataIn;
                byteWaitCounter <= 0;

                if (byteCounter == 1) begin
                    byteCounter <= 0;
                    msgState <= MSG_STATE_QUANTITY;
                end else begin
                    byteCounter <= byteCounter + 1;
                end
            end else if (byteWaitCounter == TIMEOUT_CYCLES - 1) begin
                timeOutError <= 1;
                msgState <= MSG_STATE_IDLE;
            end else begin
                byteWaitCounter <= byteWaitCounter + 1;
            end
        end
        MSG_STATE_QUANTITY: begin
            if (byteReadyEdge) begin
                quantity <= {quantity[7:0], dataIn};
                checksumAcc <= checksumAcc ^ dataIn;
                byteWaitCounter <= 0;

                if (byteCounter == 1) begin
                    byteCounter <= 0;
                    msgState <= MSG_STATE_CHECKSUM;
                end else begin
                    byteCounter <= byteCounter + 1;
                end
            end else if (byteWaitCounter == TIMEOUT_CYCLES - 1) begin
                timeOutError <= 1;
                msgState <= MSG_STATE_IDLE;
            end else begin
                byteWaitCounter <= byteWaitCounter + 1;
            end
        end
        MSG_STATE_CHECKSUM: begin
            if (byteReadyEdge) begin
                if (dataIn == checksumAcc) begin
                    messageReady <= 1;
                end else begin
                    checksumError <= 1;
                end
                byteWaitCounter <= 0;
                msgState <= MSG_STATE_IDLE;
            end else if (byteWaitCounter == TIMEOUT_CYCLES - 1) begin
                timeOutError <= 1;
                msgState <= MSG_STATE_IDLE;
            end else begin
                byteWaitCounter <= byteWaitCounter + 1;
            end
        end
    endcase
end

endmodule
