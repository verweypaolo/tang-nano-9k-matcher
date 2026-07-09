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

    initial begin
        uart_rx_line = 1; // initialize to high as expected for UART
    end

    // To help with proper UART timing
    task hold_for_bit_period;
        integer i;
        begin
            for (i = 0; i < BAUD_DIVISOR; i = i + 1) begin
                @(posedge clk);
            end
        end
    endtask

    task send_byte;
        input [7:0] data;
        integer i;
        begin
            uart_rx_line = 0; // start bit
            hold_for_bit_period; // wait one bit frame
            
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_line = data[i];
                hold_for_bit_period;
            end
            
            uart_rx_line = ^data ^ 0; // parity bit (^data = 0 if even number of ones), hardcoded for even parity
            hold_for_bit_period;
            
            uart_rx_line = 1; // stop bit
            hold_for_bit_period;
        end
    endtask

endmodule