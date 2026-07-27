`default_nettype none

module uart_tx
#(
    parameter ACC_INCREMENT = 3,
    parameter ACC_MODULUS = 8,
    parameter BAUD_DIVISOR = 234,
    parameter PARITY_ODD = 0
)
(
    input clk,
    input txByteValid,
    input [7:0] txByteData,
    output reg txByteConsumed,
    output uart_tx
);


reg [3:0] txState;
reg [12:0] txCounter;
reg [7:0] dataOut;
reg txPinRegister; // stores current transmission value
reg [2:0] txBitNumber;

reg [$clog2(ACC_MODULUS):0] txAccumulator; 
reg [12:0] txDelayFrames;

assign uart_tx = txPinRegister;

localparam TX_STATE_IDLE = 0;
localparam TX_STATE_START_BIT = 1;
localparam TX_STATE_WRITE = 2;
localparam TX_STATE_PARITY_BIT = 3;
localparam TX_STATE_STOP_BIT = 4;

reg txByteValidPrev;
wire txByteValidEdge = txByteValid & !txByteValidPrev;


initial begin
    txState = 0;
    txCounter = 0;
    dataOut = 0;
    txPinRegister = 1;
    txBitNumber = 0;
    txAccumulator = 0;
    txDelayFrames = BAUD_DIVISOR;
    txByteValidPrev = 0;
    txByteConsumed = 0;
end

always @(posedge clk) begin
    txByteValidPrev <= txByteValid;
end

always @(posedge clk) begin
    case (txState)
        TX_STATE_IDLE: begin
            txByteConsumed <= 0;
            if (txByteValidEdge) begin
                dataOut <= txByteData;
                txState <= TX_STATE_START_BIT;
                txCounter <= 0;
            end else begin
                txPinRegister <= 1; // keep line high if not transmitting
            end
        end
        TX_STATE_START_BIT: begin
            txPinRegister <= 0; // move line low to signal start of transmission (start bit)
            if ((txCounter + 1) == txDelayFrames) begin // switch to transmit after a delay_frames period
                txState <= TX_STATE_WRITE;
                txBitNumber <= 0;
                txCounter <= 0;
                // update accumulator
                if ((txAccumulator + ACC_INCREMENT) >= ACC_MODULUS) begin
                    txDelayFrames <= BAUD_DIVISOR + 1;
                    txAccumulator <= txAccumulator + ACC_INCREMENT - ACC_MODULUS;
                end else begin
                    txDelayFrames <= BAUD_DIVISOR;
                    txAccumulator <= txAccumulator + ACC_INCREMENT;
                end
            end else begin
                txCounter <= txCounter + 1;
            end
        end
        TX_STATE_WRITE: begin
            txPinRegister <= dataOut[txBitNumber]; // output appropriate bit of appropriate byte
            if ((txCounter + 1) == txDelayFrames) begin // another delay frames after start bit state, to wait after the start bit signal
                if (txBitNumber == 3'b111) begin
                    txState <= TX_STATE_PARITY_BIT;
                end else begin
                    txBitNumber <= txBitNumber + 1; // next bit
                end
                txCounter <=0;
                // update accumulator
                if ((txAccumulator + ACC_INCREMENT) >= ACC_MODULUS) begin
                    txDelayFrames <= BAUD_DIVISOR + 1;
                    txAccumulator <= txAccumulator + ACC_INCREMENT - ACC_MODULUS;
                end else begin
                    txDelayFrames <= BAUD_DIVISOR;
                    txAccumulator <= txAccumulator + ACC_INCREMENT;
                end
            end
            else begin
                txCounter <= txCounter + 1;
            end
        end
        TX_STATE_PARITY_BIT: begin
            txPinRegister <= ^dataOut ^ PARITY_ODD; // even parity; if uneven 1s this is 1, so adds the one bit to make total even
            if ((txCounter + 1) == txDelayFrames) begin
                txState <= TX_STATE_STOP_BIT;
                txCounter <= 0;
                // update accumulator
                if ((txAccumulator + ACC_INCREMENT) >= ACC_MODULUS) begin
                    txDelayFrames <= BAUD_DIVISOR + 1;
                    txAccumulator <= txAccumulator + ACC_INCREMENT - ACC_MODULUS;
                end else begin
                    txDelayFrames <= BAUD_DIVISOR;
                    txAccumulator <= txAccumulator + ACC_INCREMENT;
                end
            end
            else begin
                txCounter <= txCounter + 1;
            end
        end
        TX_STATE_STOP_BIT: begin
            txPinRegister <= 1; // already waited in previous state so can instantly transmit stop bit
            if ((txCounter + 1) == txDelayFrames) begin
                txByteConsumed <= 1;
                txState <= TX_STATE_IDLE;
                txCounter <= 0;
                // update accumulator
                if ((txAccumulator + ACC_INCREMENT) >= ACC_MODULUS) begin
                    txDelayFrames <= BAUD_DIVISOR + 1;
                    txAccumulator <= txAccumulator + ACC_INCREMENT - ACC_MODULUS;
                end else begin
                    txDelayFrames <= BAUD_DIVISOR;
                    txAccumulator <= txAccumulator + ACC_INCREMENT;
                end
            end else begin
                txCounter <= txCounter + 1;
            end
        end
    endcase
end

endmodule
