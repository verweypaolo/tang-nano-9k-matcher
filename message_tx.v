`default_nettype none

module message_tx 
#(
    parameter SENTINEL = 8'hAA, // sentinel byte
    parameter BAUD_DIVISOR = 234,
    parameter ACC_INCREMENT = 3,
    parameter ACC_MODULUS = 8
)
(
    input clk,
    output uart_tx_line,

    input sendMessageValid,
    input [7:0] msgTypeIn,
    input [15:0] orderIDIn,
    input [7:0] outcomeIn,
    input [15:0] priceIn,
    input [15:0] quantityIn,

    output reg messageSent,
    output reg txBusy,
    output reg sendWhileBusyError
);

endmodule
