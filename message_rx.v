`default_nettype none

module message_rx 
#(
    parameter SENTINEL = 8'hAA // sentinel byte
)
(
    input clk,
    input uart_rx
);

// instantiate these to connect the uart_rx outputs through
wire byteReady;
wire uartFrameError;
wire parityError;
wire [7:0] dataIn;

uart_rx uart (
    .clk(clk),
    .uart_rx(uart_rx),
    .byteReady(byteReady),
    .uartFrameError(uartFrameError),
    .parityError(parityError),
    .dataIn(dataIn)
);

reg [3:0] msgState; // track state
reg [7:0] checksumAcc; // accumulate XOR of every received byte, check checksum at the end
reg sentinelError; // assert if erroneous sentinel received
reg timeOutError; // assert if more than N cycles before receiving a byte
reg byteReadyPrev; // for edge construction
wire byteReadyEdge = byteReady & ~byteReadyPrev; // edge

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
    sentinelError = 0;
    timeOutError = 0;
    byteReadyPrev = 0;
end

always @(posedge clk) begin
    byteReadyPrev <= byteReady; // for edge functionality
end

always @(posedge clk) begin
    case (msgState)
        MSG_STATE_IDLE: begin // not sure if this state is necessary, might combine with sentinel state later
            if (byteReadyEdge) begin
                checksumAcc <= 0;
                sentinelError <= 0;
                timeOutError <= 0;
                msgState <= MSG_STATE_SENTINEL;
            end
        end
        MSG_STATE_SENTINEL: begin
            if (dataIn == SENTINEL) begin
                checksumAcc <= checksumAcc ^ dataIn;
                msgState <= MSG_STATE_MSG_TYPE;
            end else begin
                sentinelError <= 1;
                msgState <= MSG_STATE_IDLE; // move back to idle if wrong sentinel
            end
        end
    endcase
end

endmodule
