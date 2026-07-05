`default_nettype none 

module uart_rx
#(
    parameter ACC_INCREMENT = 3,
    parameter ACC_MODULUS = 8,
    parameter BAUD_DIVISOR = 234,
    parameter PARITY_ODD = 0
)
(
    input clk,
    input uart_rx,
    output reg byteReady,
    output reg uartFrameError,
    output reg parityError,
    output reg [7:0] dataIn
);


localparam HALF_DELAY_WAIT = BAUD_DIVISOR / 2; // same for 234 or 235

reg [3:0] rxState; // track which state of receiver state machine
reg [12:0] rxCounter; // count clock cycles
reg [2:0] rxBitNumber; // track which bit we are reading/have read
reg [$clog2(ACC_MODULUS):0] rxAccumulator; // $clog2 is a Verilog system function that computes the ceiling log base 2 of a value - compile time
reg [12:0] rxDelayFrames;

// states
localparam RX_STATE_IDLE = 0;
localparam RX_STATE_START_BIT = 1;
localparam RX_STATE_READ_WAIT = 2;
localparam RX_STATE_READ = 3;
localparam RX_STATE_PARITY_BIT = 4;
localparam RX_STATE_STOP_BIT = 5;

initial begin
    byteReady = 0;
    uartFrameError = 0;
    parityError = 0;
    dataIn = 0;
    rxState = RX_STATE_IDLE;
    rxCounter = 0;
    rxBitNumber = 0;
    rxAccumulator = 0;
    rxDelayFrames = BAUD_DIVISOR;
end

always @(posedge clk) begin
    case (rxState)
        RX_STATE_IDLE: begin
            if (uart_rx == 0) begin
                rxState <= RX_STATE_START_BIT;
                rxCounter <= 1;
                rxBitNumber <= 0;
                byteReady <= 0; // reset counter, bitnumber, byteready and move to start bit state
                uartFrameError <= 0; // reset possible frameError flag
                parityError <= 0; // reset possible parityError flag
            end
        end
        RX_STATE_START_BIT: begin
            if (rxCounter == HALF_DELAY_WAIT) begin
                rxState <= RX_STATE_READ_WAIT;
                rxCounter <= 1;
            end else begin
                rxCounter <= rxCounter + 1; //if we've waited half a frame, start waiting another half frame for reading, else increment clock
            end
        end
        RX_STATE_READ_WAIT: begin
            rxCounter <= rxCounter + 1;
            if ((rxCounter + 1) == rxDelayFrames) begin
                rxState <= RX_STATE_READ; // check to equal delay frames because it should start counting at half delay frames (from start bit state)
                // update accumulator
                if ((rxAccumulator + ACC_INCREMENT) >= ACC_MODULUS) begin
                    rxDelayFrames <= BAUD_DIVISOR + 1;
                    rxAccumulator <= rxAccumulator + ACC_INCREMENT - ACC_MODULUS;
                end else begin
                    rxDelayFrames <= BAUD_DIVISOR;
                    rxAccumulator <= rxAccumulator + ACC_INCREMENT;
                end
            end
        end
        RX_STATE_READ: begin
            rxCounter <= 1; // reset counter
            dataIn <= {uart_rx, dataIn[7:1]}; // shift one databit in, concat uart_rx as MSB with top 7 bits in 8 bit dataIn! (shift register)
            rxBitNumber <= rxBitNumber + 1; // track which bit we are reading
            if (rxBitNumber == 3'b111)
                rxState <= RX_STATE_PARITY_BIT;  // if bitnumber = 8 move to parity bit state
            else
                rxState <= RX_STATE_READ_WAIT; // if not, start waiting for next bit (e.g. time the next reading)
        end
        RX_STATE_PARITY_BIT: begin
            rxCounter <= rxCounter + 1;
            if ((rxCounter + 1) == rxDelayFrames) begin
                parityError <= ^{dataIn, uart_rx} ^ PARITY_ODD; // for even parity check: xor everything, if even this is 0 (no error), else 1 (error)
                rxState <= RX_STATE_STOP_BIT;
                rxCounter <= 0;
                // update accumulator
                if ((rxAccumulator + ACC_INCREMENT) >= ACC_MODULUS) begin
                    rxDelayFrames <= BAUD_DIVISOR + 1;
                    rxAccumulator <= rxAccumulator + ACC_INCREMENT - ACC_MODULUS;
                end else begin
                    rxDelayFrames <= BAUD_DIVISOR;
                    rxAccumulator <= rxAccumulator + ACC_INCREMENT;
                end
            end
        end
        RX_STATE_STOP_BIT: begin 
            rxCounter <= rxCounter + 1;
            if ((rxCounter + 1) == rxDelayFrames) begin // read ends in middle of frame, so wait one full frame to land in next middle
                uartFrameError <= (uart_rx != 1); // if stop bit not 1, assert
                byteReady <= (uart_rx == 1) && !parityError; // assert if stop bit correct and no parityError
                rxState <= RX_STATE_IDLE; // after full frame: move back to idle
                rxCounter <= 0;
                // update accumulator
                if ((rxAccumulator + ACC_INCREMENT) >= ACC_MODULUS) begin
                    rxDelayFrames <= BAUD_DIVISOR + 1;
                    rxAccumulator <= rxAccumulator + ACC_INCREMENT - ACC_MODULUS;
                end else begin
                    rxDelayFrames <= BAUD_DIVISOR;
                    rxAccumulator <= rxAccumulator + ACC_INCREMENT;
                end
            end
        end
    endcase // special for case!
end

endmodule
