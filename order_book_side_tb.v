`default_nettype none
`timescale 1ns/1ps

module test_order_book_side;
    
    // parameters
    localparam N = 8;
    localparam DESCENDING = 1;

    // inputs for order_book_side
    reg clk;
    reg insertValid;
    reg removeValid;

    reg [15:0] insertPrice;
    reg [15:0] insertQuantity;
    reg [15:0] insertOrderID;
    reg [15:0] insertSeqNum;

    // outputs from order_book_side
    wire [7:0] valid;
    wire [16*N-1:0] price;
    wire [16*N-1:0] quantity;
    wire [16*N-1:0] orderID;
    wire [16*N-1:0] seqNum;

    wire simultaneousOpError;
    wire insertFullError;
    wire removeEmptyError;


    // instantiate dut
    order_book_side
    #(
        .N(N),
        .DESCENDING(DESCENDING)
    ) dut (
        .clk(clk),
        .insertValid(insertValid),
        .removeValid(removeValid),
        .insertPrice(insertPrice),
        .insertQuantity(insertQuantity),
        .insertOrderID(insertOrderID),
        .insertSeqNum(insertSeqNum),
        .valid(valid),
        .price(price),
        .quantity(quantity),
        .orderID(orderID),
        .seqNum(seqNum),
        .simultaneousOpError(simultaneousOpError),
        .insertFullError(insertFullError),
        .removeEmptyError(removeEmptyError)
    );

    // clock
    initial clk = 0;
    always #5 clk = ~clk;

    // initialize regs
    initial begin
        insertValid = 0;
        removeValid = 0;
        insertPrice = 0;
        insertQuantity = 0;
        insertOrderID = 0;
        insertSeqNum = 0;
    end

    initial begin
        $dumpfile("order_book_side_tb.vcd"); // output waveform file
        $dumpvars(0, test_order_book_side);    // 0 = dump all levels of hierarchy, starting from this module
    end

    initial begin
        @(posedge clk); // let settle
        #1;


        // Test 1: simultaneous insert and remove - should be rejected and flagged
        insertValid = 1;
        removeValid = 1;
        insertPrice = 16'h0064;
        insertQuantity = 16'h000A;
        insertOrderID = 16'h0001;
        insertSeqNum = 16'h0000;

        @(posedge clk); // let edge register
        @(posedge clk); // let flag assert
        #1;
        // reset
        insertValid = 0;
        removeValid = 0;

        if (simultaneousOpError !== 1) begin
            $display("FAIL: simultaneousOpError not asserted when insert+remove fired together");
        end else if (valid !== 8'b0) begin
            $display("FAIL: book state changed despite simultaneous op rejection. valid=%b", valid);
        end else begin
            $display("PASS: simultaneousOpError correctly asserted, book state unchanged");
        end


        // Test 2: removing from an empty book should be rejected and flagged
        @(posedge clk);
        #1;
        removeValid = 1;

        @(posedge clk);
        @(posedge clk);

        #1;
        removeValid = 0;

        if (removeEmptyError !== 1) begin
            $display("FAIL: removeEmptyError not asserted when removing from empty book");
        end else if (valid !== 8'b0) begin
            $display("FAIL: book state changed despite removal rejection. valid=%b", valid);
        end else if (insertFullError == 1) begin
            $display("FAIL: insertFullError incorrectly asserted during empty-book removal test");
        end else begin
            $display("PASS: removeEmptyError correctly asserted, book state unchanged");
        end

        $finish;
    end

endmodule