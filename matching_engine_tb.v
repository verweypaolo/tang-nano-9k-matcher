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

    task wait_for_outcome; 
    // helpful for timing, especially as different order paths can now have differrent cycle counts (e.g. walking the book)
        integer guard;
        begin
            guard = 0;
            while (!orderFilled && !orderResting && !orderRejected
                && !wrongMsgType && !wrongMsgSide && !matchLoopOverrunError
                && guard < 200) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    task print_books;
        integer k;
        begin
            $display("");
            $display("==== Bid Book ====");
            for (k = 0; k < N; k = k + 1) begin
                if (dut.bid_book.valid[k]) begin
                    $display("  slot %0d: price=%h qty=%h orderID=%h seqNum=%h",
                            k, dut.bid_book.price[k*16 +: 16], dut.bid_book.quantity[k*16 +: 16],
                            dut.bid_book.orderID[k*16 +: 16], dut.bid_book.seqNum[k*16 +: 16]);
                end else begin
                    $display("  slot %0d: (empty)", k);
                end
            end
            $display("==== Ask Book ====");
            for (k = 0; k < N; k = k + 1) begin
                if (dut.ask_book.valid[k]) begin
                    $display("  slot %0d: price=%h qty=%h orderID=%h seqNum=%h",
                            k, dut.ask_book.price[k*16 +: 16], dut.ask_book.quantity[k*16 +: 16],
                            dut.ask_book.orderID[k*16 +: 16], dut.ask_book.seqNum[k*16 +: 16]);
                end else begin
                    $display("  slot %0d: (empty)", k);
                end
            end
            $display("===================");
            $display("");
        end
    endtask

    initial begin
        $dumpfile("matching_engine_tb.vcd");
        $dumpvars(0, test_matching_engine);
    end

    initial begin
        @(posedge clk);
        #1;


        // Test 1: single buy order into an empty book; should rest, not match
        send_order(8'h01, 16'h0001, 8'h00, 16'h0064, 16'h000A); // NEW_ORDER, id=1, BUY, price=100, qty=10

        wait_for_outcome;

        if (orderResting !== 1) begin
            $display("FAIL: orderResting not asserted for a resting buy order into an empty book");
        end else if (orderFilled === 1 || orderRejected === 1) begin
            $display("FAIL: an unexpected outcome flag was also asserted alongside orderResting");
        end else if (dut.bid_book.valid !== 8'b00000001) begin
            $display("FAIL: bid book valid mask = %b, expected 8'b00000001", dut.bid_book.valid);
        end else if (dut.bid_book.price[0*16 +: 16] !== 16'h0064
                || dut.bid_book.quantity[0*16 +: 16] !== 16'h000A
                || dut.bid_book.orderID[0*16 +: 16] !== 16'h0001) begin
            $display("FAIL: bid book slot 0 fields incorrect. price=%h qty=%h orderID=%h",
                    dut.bid_book.price[0*16 +: 16], dut.bid_book.quantity[0*16 +: 16],
                    dut.bid_book.orderID[0*16 +: 16]);
        end else if (dut.ask_book.valid !== 8'b0) begin
            $display("FAIL: ask book was disturbed by a buy-side resting order. valid=%b", dut.ask_book.valid);
        end else begin
            $display("PASS: single buy order correctly rested into empty bid book");
        end
        print_books;


        // Test 2: exact-match full fill, resting order's quantity exactly equals the incoming order's quantity
        send_order(8'h01, 16'h001E, 8'h01, 16'h0064, 16'h000A); // SELL id=30, price=100, qty=10
        wait_for_outcome;

        if (orderFilled !== 1) begin
            $display("FAIL: orderFilled not asserted for an exact-match order");
        end else if (orderResting === 1 || orderRejected === 1) begin
            $display("FAIL: an unexpected outcome flag was also asserted alongside orderFilled");
        end else if (dut.ask_book.valid !== 8'b0) begin
            $display("FAIL: ask book not empty after exact-match consume. valid=%b", dut.ask_book.valid);
        end else if (dut.bid_book.valid !== 8'b0) begin
            $display("FAIL: bid book incorrectly populated — exact match should leave nothing resting. valid=%b", dut.bid_book.valid);
        end else begin
            $display("PASS: exact-match order correctly fully filled, ask book emptied, nothing rested");
        end
        print_books;


        // Test 3: full match with leftover; resting order fully consumed,
        // unfilled remainder rests on the incoming order's own side
        send_order(8'h01, 16'h0028, 8'h01, 16'h0064, 16'h0005); // SELL id=40, price=100, qty=5
        wait_for_outcome;

        print_books;

        send_order(8'h01, 16'h0029, 8'h00, 16'h0064, 16'h000C); // BUY id=41, price=100, qty=12
        wait_for_outcome;

        if (orderResting !== 1) begin
            $display("FAIL: orderResting not asserted for a match-then-rest order");
        end else if (orderFilled === 1 || orderRejected === 1) begin
            $display("FAIL: an unexpected outcome flag was also asserted alongside orderResting");
        end else if (dut.ask_book.valid !== 8'b0) begin
            $display("FAIL: ask book not empty after full consume. valid=%b", dut.ask_book.valid);
        end else if (dut.bid_book.valid !== 8'b00000001) begin
            $display("FAIL: bid book valid mask = %b, expected 8'b00000001 (leftover resting)", dut.bid_book.valid);
        end else if (dut.bid_book.price[0*16 +: 16] !== 16'h0064
                || dut.bid_book.quantity[0*16 +: 16] !== 16'h0007
                || dut.bid_book.orderID[0*16 +: 16] !== 16'h0029) begin
            $display("FAIL: bid book slot 0 incorrect leftover. price=%h qty=%h orderID=%h",
                    dut.bid_book.price[0*16 +: 16], dut.bid_book.quantity[0*16 +: 16],
                    dut.bid_book.orderID[0*16 +: 16]);
        end else begin
            $display("PASS: resting order fully consumed, leftover quantity correctly rested");
        end
        print_books;


        // Test 4: partial match, incoming fully filled; resting order is
        // larger than the incoming order, so it gets reduced rather than removed
        send_order(8'h01, 16'h0032, 8'h01, 16'h0064, 16'h0014); // SELL id=50, price=100, qty=20
        wait_for_outcome;

        print_books;

        send_order(8'h01, 16'h0033, 8'h00, 16'h0064, 16'h0008); // BUY id=51, price=100, qty=8
        wait_for_outcome;

        if (orderFilled !== 1) begin
            $display("FAIL: orderFilled not asserted for a reduce-only partial match");
        end else if (orderResting === 1 || orderRejected === 1) begin
            $display("FAIL: an unexpected outcome flag was also asserted alongside orderFilled");
        end else if (dut.ask_book.valid !== 8'b00000001) begin
            $display("FAIL: ask book valid mask = %b, expected 8'b00000001 (resting order should remain, reduced)", dut.ask_book.valid);
        end else if (dut.ask_book.price[0*16 +: 16] !== 16'h0064
                || dut.ask_book.quantity[0*16 +: 16] !== 16'h0005
                || dut.ask_book.orderID[0*16 +: 16] !== 16'h0032) begin
            $display("FAIL: ask book slot 0 incorrect after reduce. price=%h qty=%h orderID=%h, expected qty=0x0005, orderID unchanged at 0x32",
                    dut.ask_book.price[0*16 +: 16], dut.ask_book.quantity[0*16 +: 16],
                    dut.ask_book.orderID[0*16 +: 16]);
        end else if (dut.bid_book.valid !== 8'b0) begin
            $display("FAIL: bid book should now be empty — Test 3's leftover was consumed by this test's first SELL. valid=%b",
                    dut.bid_book.valid);
        end else begin
            $display("PASS: resting order correctly reduced (not removed), incoming order fully filled");
        end
        print_books;


        // Test 5: fill the ask book to full, then confirm the next order is rejected
        send_order(8'h01, 16'h003C, 8'h01, 16'h0032, 16'h000A); // SELL id=60, price=50, qty=10
        wait_for_outcome;
        send_order(8'h01, 16'h003D, 8'h01, 16'h0046, 16'h000A); // SELL id=61, price=70, qty=10
        wait_for_outcome;
        send_order(8'h01, 16'h003E, 8'h01, 16'h0050, 16'h000A); // SELL id=62, price=80, qty=10
        wait_for_outcome;
        send_order(8'h01, 16'h003F, 8'h01, 16'h005A, 16'h000A); // SELL id=63, price=90, qty=10
        wait_for_outcome;
        send_order(8'h01, 16'h0040, 8'h01, 16'h0028, 16'h000A); // SELL id=64, price=40, qty=10
        wait_for_outcome;
        send_order(8'h01, 16'h0041, 8'h01, 16'h0019, 16'h000A); // SELL id=65, price=25, qty=10
        wait_for_outcome;
        send_order(8'h01, 16'h0042, 8'h01, 16'h000F, 16'h000A); // SELL id=66, price=15, qty=10
        wait_for_outcome;

        if (dut.ask_book.valid !== 8'b11111111) begin
            $display("FAIL: ask book valid mask = %b, expected full 8'b11111111 before reject test", dut.ask_book.valid);
        end else begin
            $display("PASS: ask book correctly filled to N=8 in preparation for reject test");
        end
        print_books;

        // Now the ask book is full: one more non-crossing SELL should be rejected
        send_order(8'h01, 16'h0043, 8'h01, 16'h003C, 16'h0005); // SELL id=67, price=60, qty=5 — should be rejected
        wait_for_outcome;

        if (orderRejected !== 1) begin
            $display("FAIL: orderRejected not asserted when resting side's book was full");
        end else if (orderFilled === 1 || orderResting === 1) begin
            $display("FAIL: an unexpected outcome flag was also asserted alongside orderRejected");
        end else if (dut.ask_book.insertFullError !== 1) begin
            $display("FAIL: order_book_side's own insertFullError not asserted. insertFullError=%b", dut.ask_book.insertFullError);
        end else if (dut.ask_book.valid !== 8'b11111111) begin
            $display("FAIL: ask book valid mask changed despite rejection. valid=%b", dut.ask_book.valid);
        end else if (dut.ask_book.orderID[7*16 +: 16] !== 16'h0032) begin
            $display("FAIL: last legitimate ask book entry (id=0x32) disturbed by the rejected order. orderID=%h",
                    dut.ask_book.orderID[7*16 +: 16]);
        end else begin
            $display("PASS: orderRejected correctly asserted when book was full, book contents unchanged");
        end
        print_books;

        
        // Test 6: an unrecognized msgType should be flagged and dropped, no book interaction
        send_order(8'h02, 16'h0044, 8'h00, 16'h0064, 16'h0005); // msgType=0x02 (not NEW_ORDER), otherwise valid-looking BUY
        wait_for_outcome;

        if (wrongMsgType !== 1) begin
            $display("FAIL: wrongMsgType not asserted for an unrecognized msgType");
        end else if (orderFilled === 1 || orderResting === 1 || orderRejected === 1) begin
            $display("FAIL: an outcome flag was incorrectly asserted alongside wrongMsgType");
        end else if (dut.bid_book.valid !== 8'b0) begin
            $display("FAIL: bid book was disturbed by a message with an invalid msgType. valid=%b", dut.bid_book.valid);
        end else if (dut.ask_book.valid !== 8'b11111111) begin
            $display("FAIL: ask book was unexpectedly altered. valid=%b, expected unchanged 8'b11111111", dut.ask_book.valid);
        end else begin
            $display("PASS: wrongMsgType correctly asserted, no book interaction occurred");
        end
        print_books;


        // Test 7: an unrecognized side value should be flagged and dropped, no book interaction
        send_order(8'h01, 16'h0045, 8'h02, 16'h0064, 16'h0005); // valid NEW_ORDER, but side=0x02 (neither BUY nor SELL)
        wait_for_outcome;

        if (wrongMsgSide !== 1) begin
            $display("FAIL: wrongMsgSide not asserted for an unrecognized side value");
        end else if (orderFilled === 1 || orderResting === 1 || orderRejected === 1) begin
            $display("FAIL: an outcome flag was incorrectly asserted alongside wrongMsgSide");
        end else if (dut.bid_book.valid !== 8'b0) begin
            $display("FAIL: bid book was disturbed by a message with an invalid side. valid=%b", dut.bid_book.valid);
        end else if (dut.ask_book.valid !== 8'b11111111) begin
            $display("FAIL: ask book was unexpectedly altered. valid=%b, expected unchanged 8'b11111111", dut.ask_book.valid);
        end else begin
            $display("PASS: wrongMsgSide correctly asserted, no book interaction occurred");
        end
        print_books;


        // Test 8: multi-iteration match walk: one incoming order fully drains the entire 8-entry ask book across 7 
        // "keep walking" iterations plus a final exact match, without hitting matchLoopOverrunError
        send_order(8'h01, 16'h0046, 8'h00, 16'h0064, 16'h004B); // BUY id=70, price=100, qty=75
        wait_for_outcome;

        if (orderFilled !== 1) begin
            $display("FAIL: orderFilled not asserted after full-book match walk");
        end else if (orderResting === 1 || orderRejected === 1) begin
            $display("FAIL: an unexpected outcome flag was also asserted alongside orderFilled");
        end else if (matchLoopOverrunError === 1) begin
            $display("FAIL: matchLoopOverrunError incorrectly asserted during a valid 8-entry walk");
        end else if (dut.ask_book.valid !== 8'b0) begin
            $display("FAIL: ask book not empty after full walk. valid=%b", dut.ask_book.valid);
        end else if (dut.bid_book.valid !== 8'b0) begin
            $display("FAIL: bid book incorrectly populated — fully-filled buy should leave nothing resting. valid=%b", dut.bid_book.valid);
        end else begin
            $display("PASS: multi-iteration match walk correctly drained all 8 resting ask orders");
        end
        print_books;

        $finish;
    end

endmodule
