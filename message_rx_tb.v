`default_nettype none
`timescale 1ns/1ps

module test;

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
    
    localparam SENTINEL = 8'hAA;
    localparam BAUD_DIVISOR = 8; // faster for simulation purposes
    

    message_rx
    #(
        .SENTINEL(SENTINEL),
        .BAUD_DIVISOR(BAUD_DIVISOR),
        .ACC_INCREMENT(0)
        
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

    task send_order_bad_sentinel;
        begin
            send_byte(8'hBB);
        end
    endtask

    task send_order_bad_checksum;
        input [7:0] msgTypeIn; // suffix In to avoid name collisions with module level wires
        input [15:0] orderIDIn;
        input [7:0] sideIn;
        input [15:0] priceIn;
        input [15:0] quantityIn;
        reg [7:0] checksum;
        begin
            checksum = 8'hBB 
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

    task send_order_timeout;
        integer i;
        begin
            send_byte(SENTINEL);
            for (i = 0; i < BAUD_DIVISOR * 11 * 20; i = i + 1) begin
                @(posedge clk);
            end
        end
    endtask

    task send_order_resync_after_garbage;
        begin
            send_byte(8'hBB); // send garbage byte
            send_order(8'h01, 16'h1234, 8'h00, 
            16'h0050, 16'h0064); // immediately send valid order
        end
    endtask

    initial begin
        $dumpfile("message_rx_tb.vcd"); // output waveform file
        $dumpvars(0, test);    // 0 = dump all levels of hierarchy, starting from this module
    end


    // call tests
    initial begin
        #20; // brief settle time (2 clock cycles equivalent)

        // Normal order test
        send_order(8'h01, 16'h1234, 8'h00, 
        16'h0050, 16'h0064);

        // one clock cycle wait to allow the state machine to process and drive outputs
        @(posedge clk); 

        if (messageReady !== 1) begin
            $display("FAIL: messageReady not asserted after valid order");
        end else if (msgType !== 8'h01 || orderID !== 16'h1234 || side !== 8'h00
                 || price !== 16'h0050 || quantity !== 16'h0064) begin
            $display("FAIL: fields mismatch. Got msgType=%h orderID=%h side=%h price=%h quantity=%h",
          msgType, orderID, side, price, quantity);
        end else begin
            $display("PASS: valid order received and decoded correctly");
        end

        // Notice no wait between tests: test if return to IDLE in time

        // Bad sentinel test
        send_order_bad_sentinel;
        @(posedge clk);
        @(posedge clk);

        if (sentinelError !== 1) begin
            $display("FAIL: sentinelError not asserted after invalid sentinel");
        end else if (messageReady === 1) begin
            $display("FAIL: messageReady incorrectly asserted after invalid sentinel");
        end else begin
            $display("PASS: sentinelError correctly asserted, messageReady correctly not asserted");
        end

        // Bad checksum test
        send_order_bad_checksum(8'h01, 16'h1234, 8'h00, 
        16'h0050, 16'h0064);
        @(posedge clk);

        if (checksumError !== 1) begin
            $display("FAIL: checksumError not asserted after invalid checksum");
        end else if (messageReady === 1) begin
            $display("FAIL: messageReady incorrectly asserted after invalid checksum");
        end else begin
            $display("PASS: checksumError correctly asserted, messageReady correctly not asserted");
        end

        // Timeout error test
        send_order_timeout;
        // no wait, happens internally in test

        if (timeOutError !== 1) begin
            $display("FAIL: timeOutError not asserted after prolonged silence");
        end else if (messageReady === 1) begin
            $display("FAIL: messageReady incorrectly asserted after timeout");
        end else if (sentinelError === 1) begin
            $display("FAIL: sentinelError incorrectly asserted after timeout");
        end else if (checksumError === 1) begin
            $display("FAIL: checksumError incorrectly asserted after timeout");
        end else begin
            $display("PASS: timeOutError correctly asserted, no other flags incorrectly set");
        end

        //  Resync after garbage test
        send_order_resync_after_garbage;
        @(posedge clk);

        if (messageReady !== 1) begin
            $display("FAIL: messageReady not asserted after resync from garbage byte");
        end else if (msgType !== 8'h01 || orderID !== 16'h1234 || side !== 8'h00
                    || price !== 16'h0050 || quantity !== 16'h0064) begin
            $display("FAIL: fields mismatch after resync. Got msgType=%h orderID=%h side=%h price=%h quantity=%h",
                    msgType, orderID, side, price, quantity);
        end else begin
            $display("PASS: correctly resynced after garbage byte and decoded valid order");
        end

        // Back to back valid messages test
        send_order(8'h01, 16'h1234, 8'h00, 16'h0050, 16'h0064);
        @(posedge clk);

        if (messageReady !== 1 || msgType !== 8'h01 || orderID !== 16'h1234
            || side !== 8'h00 || price !== 16'h0050 || quantity !== 16'h0064) begin
            $display("FAIL: first back-to-back message not decoded correctly. Got msgType=%h orderID=%h side=%h price=%h quantity=%h",
                    msgType, orderID, side, price, quantity);
        end else begin
            $display("PASS: first back-to-back message decoded correctly");
        end

        send_order(8'h02, 16'h5678, 8'h01, 16'h0025, 16'h0032);
        @(posedge clk);

        if (messageReady !== 1 || msgType !== 8'h02 || orderID !== 16'h5678
            || side !== 8'h01 || price !== 16'h0025 || quantity !== 16'h0032) begin
            $display("FAIL: second back-to-back message not decoded correctly (checksumAcc or other state may not have reset). Got msgType=%h orderID=%h side=%h price=%h quantity=%h",
                    msgType, orderID, side, price, quantity);
        end else begin
            $display("PASS: second back-to-back message decoded correctly — reset behavior confirmed");
        end

        $finish;
    end

endmodule
