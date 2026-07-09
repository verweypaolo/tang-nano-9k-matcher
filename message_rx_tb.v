`default_nettype none
`timescale 1ns/1ps

module message_rx_tb;

    reg clk;
    reg uart_rx_line;

    wire messageReady;
    wire sentinelError;
    wire timeOutError;
    wire checksumError;

    wire [7:0] msgType;
    wire [15:0] orderID;
    wire [7:0] side;
    wire [15:0] price;
    wire [15:0] quantity;

    localparam BAUD_DIVISOR = 8; // faster for simulation purposes

    message_rx
    #(
        .BAUD_DIVISOR(BAUD_DIVISOR) 
    ) dut (
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

    // clock generation
    initial clk = 0;
    always #5 clk = ~clk;

endmodule