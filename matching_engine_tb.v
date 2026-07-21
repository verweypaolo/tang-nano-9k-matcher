`default_nettype none
`timescale 1ns/1ps

module test_matching_engine;

    localparam SENTINEL = 8'hAA;
    localparam BAUD_DIVISOR = 8;
    localparam ACC_INCREMENT = 0;
    localparam ACC_MODULUS = 8;
    localparam N = 8;

    reg clk;
    reg uart_rx_line;

    wire orderFilled;
    wire orderResting;
    wire orderRejected;

    wire wrongMsgType;
    wire wrongMsgSide;
    wire matchLoopOverrunError;


    matching_engine
    #(
        .SENTINEL(SENTINEL),
        .BAUD_DIVISOR(BAUD_DIVISOR),
        .ACC_INCREMENT(ACC_INCREMENT),
        .ACC_MODULUS(ACC_MODULUS),
        .N(N)
    ) dut (
        .clk(clk),
        .uart_rx_line(uart_rx_line),
        .orderFilled(orderFilled),
        .orderResting(orderResting),
        .orderRejected(orderRejected),
        .wrongMsgType(wrongMsgType),
        .wrongMsgSide(wrongMsgSide),
        .matchLoopOverrunError(matchLoopOverrunError)
    );


    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        uart_rx_line = 1;
    end


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

    task send_order;
        input [7:0] msgTypeIn; // suffix In to avoid name collisions with module level wires
        input [15:0] orderIDIn;
        input [7:0] sideIn;
        input [15:0] priceIn;
        input [15:0] quantityIn;
        reg [7:0] checksum;
        begin
            checksum = SENTINEL 
                ^ msgTypeIn 
                ^ orderIDIn[15:8]
                ^ orderIDIn[7:0] 
                ^ sideIn 
                ^ priceIn[15:8]
                ^ priceIn[7:0]
                ^ quantityIn[15:8]
                ^ quantityIn[7:0];
            send_byte(SENTINEL);
            send_byte(msgTypeIn);
            send_byte(orderIDIn[15:8]); // high byte first (big endian)
            send_byte(orderIDIn[7:0]);
            send_byte(sideIn);
            send_byte(priceIn[15:8]);
            send_byte(priceIn[7:0]);
            send_byte(quantityIn[15:8]);
            send_byte(quantityIn[7:0]);
            send_byte(checksum);
        end
    endtask



endmodule
