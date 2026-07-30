`default_nettype none
`timescale 1ns/1ps

module test_message_tx;

    reg clk;
    wire uart_tx_line;

    reg sendMessageValid;
    reg [7:0] msgType;
    reg [15:0] orderID;
    reg [7:0] outcome;
    reg [15:0] price;
    reg [15:0] quantity;

    wire messageSent;
    wire txBusy;
    wire sendWhileBusyError;


    localparam SENTINEL = 8'hAA;
    localparam BAUD_DIVISOR = 8;
    localparam ACC_INCREMENT = 0;

    message_tx
    #(
        .SENTINEL(SENTINEL),
        .BAUD_DIVISOR(BAUD_DIVISOR),
        .ACC_INCREMENT(ACC_INCREMENT)
    ) dut (
        .clk(clk),
        .uart_tx_line(uart_tx_line),
        .sendMessageValid(sendMessageValid),
        .msgTypeIn(msgType),
        .orderIDIn(orderID),
        .outcomeIn(outcome),
        .priceIn(price),
        .quantityIn(quantity),
        .messageSent(messageSent),
        .txBusy(txBusy),
        .sendWhileBusyError(sendWhileBusyError)
    );


    wire rxMessageReady;
    wire rxSentinelError;
    wire rxTimeOutError;
    wire rxChecksumError;
    wire [7:0] rxMsgType;
    wire [15:0] rxOrderID;
    wire [7:0] rxSide;
    wire [15:0] rxPrice;
    wire [15:0] rxQuantity;

    message_rx
    #(
        .SENTINEL(SENTINEL),
        .BAUD_DIVISOR(BAUD_DIVISOR),
        .ACC_INCREMENT(ACC_INCREMENT)
    ) receiver (
        .clk(clk),
        .uart_rx(uart_tx_line),
        .messageReady(rxMessageReady),
        .sentinelError(rxSentinelError),
        .timeOutError(rxTimeOutError),
        .checksumError(rxChecksumError),
        .msgType(rxMsgType),
        .orderID(rxOrderID),
        .side(rxSide),
        .price(rxPrice),
        .quantity(rxQuantity)
    );


    initial clk = 0;
    always #5 clk = !clk;

    initial begin
        sendMessageValid = 0;
        msgType = 0;
        orderID = 0;
        outcome = 0;
        price = 0;
        quantity = 0;
    end

    initial begin
        $dumpfile("message_tx_tb.vcd"); // output waveform file
        $dumpvars(0, test_message_tx);    // 0 = dump all levels of hierarchy, starting from this module
    end

endmodule
