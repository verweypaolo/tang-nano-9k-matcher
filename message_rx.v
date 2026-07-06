`default_nettype none

module message_rx (
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

endmodule
