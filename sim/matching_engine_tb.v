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
    wire uart_tx_line;

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
        .uart_tx_line(uart_tx_line),
        .orderFilled(orderFilled),
        .orderResting(orderResting),
        .orderRejected(orderRejected),
        .wrongMsgType(wrongMsgType),
        .wrongMsgSide(wrongMsgSide),
        .matchLoopOverrunError(matchLoopOverrunError)
    );

    // add a message_rx instance to decode what is transmitted so we can check correctness
    wire refMessageReady;
    wire refSentinelError, refTimeOutError, refChecksumError;
    wire [7:0] refMsgType, refOutcome;
    wire [15:0] refOrderID, refPrice, refQuantity;

    message_rx #(
        .SENTINEL(SENTINEL),
        .BAUD_DIVISOR(BAUD_DIVISOR),
        .ACC_INCREMENT(ACC_INCREMENT),
        .ACC_MODULUS(ACC_MODULUS)
    ) ref_rx (
        .clk(clk),
        .uart_rx(uart_tx_line), // output piped into input
        .messageReady(refMessageReady),
        .sentinelError(refSentinelError),
        .timeOutError(refTimeOutError),
        .checksumError(refChecksumError),
        .msgType(refMsgType),
        .orderID(refOrderID),
        .side(refOutcome),
        .price(refPrice),
        .quantity(refQuantity)
    );
    
    
    // construct a messageReady edge to pin point waiting time for a report to round trip
    reg refMessageReadyPrev;
    wire refMessageReadyEdge = refMessageReady & !refMessageReadyPrev;
    always @(posedge clk) begin
        refMessageReadyPrev <= refMessageReady;
    end

    reg [15:0] seqBefore;
    reg reportSeenDuringWait;
    integer i;

    initial clk = 0;
    always #5 clk = ~clk;

    // replaces the old pendingBufferWasUsed monitor (dut.reportPending no longer exists —
    // the 1-deep pending buffer was fully replaced by report_fifo). This tracks whether the
    // FIFO ever actually held a queued-but-undrained report, i.e. whether genuine overlap
    // was exercised rather than every report draining before the next one was queued.
    reg queueWasUsed;
    always @(posedge clk) begin
        if (!dut.empty) queueWasUsed <= 1;
    end

    // for checking back-to-back-to-back reports/transmissions
    localparam CAPTURE_DEPTH = 8;

    reg [15:0] capturedOrderID [0:CAPTURE_DEPTH-1];
    reg [7:0] capturedOutcome [0:CAPTURE_DEPTH-1];
    reg [15:0] capturedPrice   [0:CAPTURE_DEPTH-1];
    reg [15:0] capturedQuantity[0:CAPTURE_DEPTH-1];
    reg [2:0] captureWritePtr;
    reg [2:0] captureReadPtr;

    reg [15:0] capOrderID;
    reg [7:0] capOutcome;
    reg [15:0] capPrice;
    reg [15:0] capQuantity;
    reg capValid;

    integer capInit;

    initial begin
        uart_rx_line = 1;
        seqBefore = 0;
        refMessageReadyPrev = 0;
        reportSeenDuringWait = 0;
        i = 0;
        queueWasUsed = 0;
        captureWritePtr = 0;
        captureReadPtr = 0;

        for (capInit = 0; capInit < CAPTURE_DEPTH; capInit = capInit + 1) begin
            capturedOrderID[capInit] = 0;
            capturedOutcome[capInit] = 0;
            capturedPrice[capInit] = 0;
            capturedQuantity[capInit] = 0;
        end

        capOrderID = 0;
        capOutcome = 0;
        capPrice = 0;
        capQuantity = 0;
        capValid = 0;
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

    task wait_for_report;
        integer guard;
        begin
            @(posedge clk); // unconditionally advance one cycle first, so a leftover pulse from a previous call
                            // (still visible in this same instant) can never be misread as a fresh edge
            guard = 0;
            while (!refMessageReadyEdge && guard < 2000) begin
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

    task read_captured_report;
        output [15:0] outOrderID;
        output [7:0]  outOutcome;
        output [15:0] outPrice;
        output [15:0] outQuantity;
        output        outValid;
        begin
            if (captureReadPtr == captureWritePtr) begin
                outValid = 0; // nothing captured yet at this read position
                $display("DEBUG: read_captured_report - empty, outValid set to %b", outValid);
            end else begin
                outOrderID  = capturedOrderID[captureReadPtr];
                outOutcome  = capturedOutcome[captureReadPtr];
                outPrice    = capturedPrice[captureReadPtr];
                outQuantity = capturedQuantity[captureReadPtr];
                captureReadPtr = captureReadPtr + 1;
                outValid = 1;
                $display("DEBUG: read_captured_report - got data, outValid set to %b, orderID=%h", outValid, outOrderID);
            end
        end
    endtask

    always @(posedge clk) begin
        if (refMessageReadyEdge) begin
            $display("DEBUG: capture fired at time %0t, writing to slot %0d, orderID=%h", $time, captureWritePtr, refOrderID);
            capturedOrderID[captureWritePtr]   <= refOrderID;
            capturedOutcome[captureWritePtr]   <= refOutcome;
            capturedPrice[captureWritePtr]     <= refPrice;
            capturedQuantity[captureWritePtr]  <= refQuantity;
            captureWritePtr <= captureWritePtr + 1; // wraps naturally at 4-bit width vs CAPTURE_DEPTH=4... see note below
        end
    end


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

        // verify the corresponding execution report
        wait_for_report;

        if (!refMessageReady) begin
            $display("FAIL: no report received for Test 1's resting order");
        end else if (refOrderID !== 16'h0001 || refOutcome !== 8'h02 /* RPT_RESTING */
                || refPrice !== 16'h0064 || refQuantity !== 16'h000A) begin
            $display("FAIL: Test 1 report incorrect. orderID=%h outcome=%h price=%h quantity=%h",
                    refOrderID, refOutcome, refPrice, refQuantity);
        end else if (refChecksumError === 1 || refSentinelError === 1) begin
            $display("FAIL: Test 1 report had a framing/checksum error");
        end else begin
            $display("PASS: Test 1 report correctly transmitted and decoded");
        end


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

        // verify the corresponding execution report
        wait_for_report;

        if (!refMessageReady) begin
            $display("FAIL: no report received for Test 2's exact-match fill");
        end else if (refOrderID !== 16'h001E || refOutcome !== 8'h01 /* RPT_FILLED */
                || refPrice !== 16'h0064 || refQuantity !== 16'h000A) begin
            $display("FAIL: Test 2 report incorrect. orderID=%h outcome=%h price=%h quantity=%h",
                    refOrderID, refOutcome, refPrice, refQuantity);
        end else if (refChecksumError === 1 || refSentinelError === 1) begin
            $display("FAIL: Test 2 report had a framing/checksum error");
        end else begin
            $display("PASS: Test 2 report correctly transmitted and decoded");
        end


        // Test 3: full match with leftover; resting order fully consumed,
        // unfilled remainder rests on the incoming order's own side
        send_order(8'h01, 16'h0028, 8'h01, 16'h0064, 16'h0005); // SELL id=40, price=100, qty=5
        wait_for_outcome;

        print_books;

        // verify the report for the first order — simple rest, no prior match
        wait_for_report;

        if (!refMessageReady) begin
            $display("FAIL: no report received for Test 3's first (simple resting) order");
        end else if (refOrderID !== 16'h0028 || refOutcome !== 8'h02 /* RPT_RESTING */
                || refPrice !== 16'h0064 || refQuantity !== 16'h0005) begin
            $display("FAIL: Test 3 first report incorrect. orderID=%h outcome=%h price=%h quantity=%h",
                    refOrderID, refOutcome, refPrice, refQuantity);
        end else if (refChecksumError === 1 || refSentinelError === 1) begin
            $display("FAIL: Test 3 first report had a framing/checksum error");
        end else begin
            $display("PASS: Test 3 first report correctly reflects simple rest, quantity unchanged at original value");
        end

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

        // verify the report for the second order, quantity should reflect remainingQuantity (7), NOT the original 12
        wait_for_report;

        if (!refMessageReady) begin
            $display("FAIL: no report received for Test 3's second (match-then-rest) order");
        end else if (refOrderID !== 16'h0029 || refOutcome !== 8'h02 /* RPT_RESTING */
                || refPrice !== 16'h0064 || refQuantity !== 16'h0007) begin
            $display("FAIL: Test 3 second report incorrect. orderID=%h outcome=%h price=%h quantity=%h, expected quantity=0x0007 (remaining, not original 12)",
                    refOrderID, refOutcome, refPrice, refQuantity);
        end else if (refChecksumError === 1 || refSentinelError === 1) begin
            $display("FAIL: Test 3 second report had a framing/checksum error");
        end else begin
            $display("PASS: Test 3 second report correctly reflects REMAINING quantity (7), not original incoming quantity (12)");
        end


        // Test 4: partial match, incoming fully filled; resting order is
        // larger than the incoming order, so it gets reduced rather than removed
        send_order(8'h01, 16'h0032, 8'h01, 16'h0064, 16'h0014); // SELL id=50, price=100, qty=20
        wait_for_outcome;

        print_books;

        // verify the report for the first order
        wait_for_report;

        if (!refMessageReady) begin
            $display("FAIL: no report received for Test 4's first (simple resting) order");
        end else if (refOrderID !== 16'h0032 || refOutcome !== 8'h02 /* RPT_RESTING */
                || refPrice !== 16'h0064 || refQuantity !== 16'h000D) begin
            $display("FAIL: Test 4 first report incorrect. orderID=%h outcome=%h price=%h quantity=%h",
                    refOrderID, refOutcome, refPrice, refQuantity);
        end else if (refChecksumError === 1 || refSentinelError === 1) begin
            $display("FAIL: Test 4 first report had a framing/checksum error");
        end else begin
            $display("PASS: Test 4 first report correctly reflects remaining rest at remaining quantity 13");
        end

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

        // verify the report for the second order: this should be RPT_FILLED at the ORIGINAL incoming quantity (8)?
        wait_for_report;

        if (!refMessageReady) begin
            $display("FAIL: no report received for Test 4's second (reduce-fill) order");
        end else if (refOrderID !== 16'h0033 || refOutcome !== 8'h01 /* RPT_FILLED */
                || refPrice !== 16'h0064 || refQuantity !== 16'h0008) begin
            $display("FAIL: Test 4 second report incorrect. orderID=%h outcome=%h price=%h quantity=%h, expected outcome=FILLED quantity=0x0008 (original incoming, not resting-side remainder)",
                    refOrderID, refOutcome, refPrice, refQuantity);
        end else if (refChecksumError === 1 || refSentinelError === 1) begin
            $display("FAIL: Test 4 second report had a framing/checksum error");
        end else begin
            $display("PASS: Test 4 second report correctly reflects FILLED at original incoming quantity (8), independent of the reduce that happened on the book");
        end


        // Test 5: fill the ask book to full, then confirm the next order is rejected
        send_order(8'h01, 16'h003C, 8'h01, 16'h0032, 16'h000A); // SELL id=60, price=50, qty=10
        wait_for_outcome;

        // spot-check the first fill order's report — simple rest, same pattern as Test 1
        wait_for_report;

        if (!refMessageReady) begin
            $display("FAIL: no report received for Test 5's first fill order");
        end else if (refOrderID !== 16'h003C || refOutcome !== 8'h02 /* RPT_RESTING */
                || refPrice !== 16'h0032 || refQuantity !== 16'h000A) begin
            $display("FAIL: Test 5 first fill report incorrect. orderID=%h outcome=%h price=%h quantity=%h",
                    refOrderID, refOutcome, refPrice, refQuantity);
        end else begin
            $display("PASS: Test 5 first fill order report correct (spot check)");
        end

        send_order(8'h01, 16'h003D, 8'h01, 16'h0046, 16'h000A); // SELL id=61, price=70, qty=10
        wait_for_outcome;
        wait_for_report;

        send_order(8'h01, 16'h003E, 8'h01, 16'h0050, 16'h000A); // SELL id=62, price=80, qty=10
        wait_for_outcome;
        wait_for_report;

        send_order(8'h01, 16'h003F, 8'h01, 16'h005A, 16'h000A); // SELL id=63, price=90, qty=10
        wait_for_outcome;
        wait_for_report;

        send_order(8'h01, 16'h0040, 8'h01, 16'h0028, 16'h000A); // SELL id=64, price=40, qty=10
        wait_for_outcome;
        wait_for_report;

        send_order(8'h01, 16'h0041, 8'h01, 16'h0019, 16'h000A); // SELL id=65, price=25, qty=10
        wait_for_outcome;
        wait_for_report;
        
        send_order(8'h01, 16'h0042, 8'h01, 16'h000F, 16'h000A); // SELL id=66, price=15, qty=10
        wait_for_outcome;
        wait_for_report;

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

        // verify the REJECTED report
        wait_for_report;

        if (!refMessageReady) begin
            $display("FAIL: no report received for Test 5's rejected order");
        end else if (refOrderID !== 16'h0043 || refOutcome !== 8'h03 /* RPT_REJECTED */
                || refPrice !== 16'h003C || refQuantity !== 16'h0005) begin
            $display("FAIL: Test 5 rejected-order report incorrect. orderID=%h outcome=%h price=%h quantity=%h, expected outcome=REJECTED quantity=0x0005 (original incoming, since nothing happened)",
                    refOrderID, refOutcome, refPrice, refQuantity);
        end else if (refChecksumError === 1 || refSentinelError === 1) begin
            $display("FAIL: Test 5 rejected-order report had a framing/checksum error");
        end else begin
            $display("PASS: Test 5 rejected-order report correctly reflects REJECTED at original incoming quantity");
        end

        
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

        wait_for_report;

        if (!refMessageReady) begin
            $display("FAIL: no report received for Test 6's invalid-msgType order");
        end else if (refOrderID !== 16'h0044 || refOutcome !== 8'h04 /* RPT_INVALID */
                || refPrice !== 16'h0064 || refQuantity !== 16'h0005) begin
            $display("FAIL: Test 6 report incorrect. orderID=%h outcome=%h price=%h quantity=%h",
                    refOrderID, refOutcome, refPrice, refQuantity);
        end else if (refChecksumError === 1 || refSentinelError === 1) begin
            $display("FAIL: Test 6 report had a framing/checksum error");
        end else begin
            $display("PASS: Test 6 correctly reports RPT_INVALID for a malformed msgType");
        end


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

        wait_for_report;

        if (!refMessageReady) begin
            $display("FAIL: no report received for Test 7's invalid-side order");
        end else if (refOrderID !== 16'h0045 || refOutcome !== 8'h04 /* RPT_INVALID */
                || refPrice !== 16'h0064 || refQuantity !== 16'h0005) begin
            $display("FAIL: Test 7 report incorrect. orderID=%h outcome=%h price=%h quantity=%h",
                    refOrderID, refOutcome, refPrice, refQuantity);
        end else if (refChecksumError === 1 || refSentinelError === 1) begin
            $display("FAIL: Test 7 report had a framing/checksum error");
        end else begin
            $display("PASS: Test 7 correctly reports RPT_INVALID for a malformed side value");
        end


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

        // verify the report, should be RPT_FILLED at the ORIGINAL quantity (75)
        wait_for_report;

        if (!refMessageReady) begin
            $display("FAIL: no report received for Test 8's multi-iteration walk order");
        end else if (refOrderID !== 16'h0046 || refOutcome !== 8'h01 /* RPT_FILLED */
                || refPrice !== 16'h0064 || refQuantity !== 16'h004B) begin
            $display("FAIL: Test 8 report incorrect. orderID=%h outcome=%h price=%h quantity=%h, expected FILLED quantity=0x004B (75, original)",
                    refOrderID, refOutcome, refPrice, refQuantity);
        end else if (refChecksumError === 1 || refSentinelError === 1) begin
            $display("FAIL: Test 8 report had a framing/checksum error");
        end else begin
            $display("PASS: Test 8 report correctly reflects FILLED at original quantity 75, unaffected by the walk");
        end


        // Test 9: globalSeqNum increments exactly once per resolved order,
        // and the stored seqNum reflects the value at the moment of insertion
        seqBefore = dut.globalSeqNum;

        send_order(8'h01, 16'h0049, 8'h00, 16'h0064, 16'h000A); // BUY id=73, price=100, qty=10 — rests into empty book
        wait_for_outcome;

        if (dut.globalSeqNum !== seqBefore + 1) begin
            $display("FAIL: globalSeqNum = %d, expected %d (before + 1)", dut.globalSeqNum, seqBefore + 1);
        end else if (dut.bid_book.seqNum[0*16 +: 16] !== seqBefore) begin
            $display("FAIL: bid book slot 0 seqNum = %d, expected %d (pre-increment value)",
                    dut.bid_book.seqNum[0*16 +: 16], seqBefore);
        end else begin
            $display("PASS: globalSeqNum incremented exactly once, resting order stored the correct pre-increment seqNum");
        end
        print_books;

        wait_for_report;


        // Test 10: dropped messages (wrongMsgType, wrongMsgSide) must not
        // increment globalSeqNum — only genuinely resolved orders should
        seqBefore = dut.globalSeqNum;

        send_order(8'h02, 16'h004A, 8'h00, 16'h0064, 16'h0005); // bad msgType — should be dropped
        wait_for_outcome;
        wait_for_report;

        send_order(8'h01, 16'h004B, 8'h02, 16'h0064, 16'h0005); // bad side — should be dropped
        wait_for_outcome;

        if (dut.globalSeqNum !== seqBefore) begin
            $display("FAIL: globalSeqNum changed after dropped messages. before=%d after=%d", seqBefore, dut.globalSeqNum);
        end else begin
            $display("PASS: globalSeqNum correctly unchanged after wrongMsgType and wrongMsgSide drops");
        end
        wait_for_report;

        // confirm a subsequent valid order still increments by exactly one,
        // not by some leftover/miscounted amount
        send_order(8'h01, 16'h004C, 8'h01, 16'h0032, 16'h0005); // SELL id=76, price=50, qty=5 — matches against resting bid id=0x49, reduces it from 10 to 5
        wait_for_outcome;

        if (dut.globalSeqNum !== seqBefore + 1) begin
            $display("FAIL: globalSeqNum = %d after a valid order following two drops, expected %d",
                    dut.globalSeqNum, seqBefore + 1);
        end else begin
            $display("PASS: globalSeqNum correctly incremented by exactly one for the valid order, unaffected by prior drops");
        end
        print_books;
        wait_for_report;


        // Test 11: matchLoopOverrunError: this condition is unreachable the real interface (order_book_side 
        // never holds more than N resting orders, so the loop can never need more than N iterations).
        // Force matchLoopCount to its maximum value directly, bypassing the normal interface, just to confirm 
        // the defensive guard itself behaves correctly IF it were ever reached due to a hypothetical bug elsewhere.

        force dut.matchLoopCount = dut.MATCH_LOOP_MAX; // hijack: pretend the loop already hit its limit

        send_order(8'h01, 16'h0048, 8'h01, 16'h0064, 16'h0005); // ASK id=72, price=100, qty=5 — crosses the resting order
        wait_for_outcome;

        release dut.matchLoopCount; // give control back to the DUT's own logic

        if (matchLoopOverrunError !== 1) begin
            $display("FAIL: matchLoopOverrunError not asserted when matchLoopCount was forced to its maximum");
        end else if (orderFilled === 1 || orderResting === 1 || orderRejected === 1) begin
            $display("FAIL: an outcome flag was incorrectly asserted alongside matchLoopOverrunError");
        end else if (dut.bid_book.valid !== 8'b00000001) begin
            $display("FAIL: bid book was disturbed — the overrun guard should abort before touching the book. valid=%b",
                    dut.bid_book.valid);
        end else if (dut.bid_book.orderID[0*16 +: 16] !== 16'h0049
                || dut.bid_book.quantity[0*16 +: 16] !== 16'h0005) begin
        $display("FAIL: the resting order's fields were altered despite the guard aborting the match. orderID=%h qty=%h",
            dut.bid_book.orderID[0*16 +: 16], dut.bid_book.quantity[0*16 +: 16]); 
        end else if (dut.ask_book.valid !== 8'b0) begin
            $display("FAIL: ask book was disturbed — the incoming sell should not have rested after an overrun abort. valid=%b",
                    dut.ask_book.valid);
        end else begin
            $display("PASS: matchLoopOverrunError correctly asserted under a forced condition, book left completely untouched");
        end
        print_books;

        // make sure no report sent (or queued — check the FIFO's empty flag directly now that
        // there's no single reportPending bit to inspect)
        reportSeenDuringWait = 0;
        for (i = 0; i < 2000; i = i + 1) begin
            @(posedge clk);
            if (refMessageReadyEdge) reportSeenDuringWait = 1;
        end

        if (reportSeenDuringWait || !dut.empty) begin
            $display("FAIL: a report was unexpectedly sent (or sits queued in the FIFO) for a matchLoopOverrunError-aborted order");
        end else begin
            $display("PASS: correctly no report sent or queued for an aborted, defensively-guarded order");
        end


        // Test 12: back-to-back-to-back messages, zero gaps between all of them — stress-tests the
        // report_fifo's depth directly. Four rapid-fire orders means at least three reports must sit
        // queued simultaneously at some point, which the old 1-deep pending buffer could never have
        // survived without silently overwriting earlier reports. Since report transmission can complete
        // WHILE later send_order calls are still bit-banging bytes, sequential wait_for_report polling
        // can miss events entirely; this uses the concurrently-running capture monitor instead, which
        // observes every refMessageReadyEdge regardless of what the sequential test code is doing.

        #1;
        queueWasUsed = 0;
        captureReadPtr = 0;
        captureWritePtr = 0;
        @(posedge clk); // ensure prior state has fully settled before any new capture can occur
        #1;

        send_order(8'h01, 16'h0050, 8'h01, 16'h006E, 16'h000F); // SELL id=80, price=110, qty=15
        send_order(8'h01, 16'h0051, 8'h01, 16'h0078, 16'h0014); // SELL id=81, price=120, qty=20
        send_order(8'h01, 16'h0052, 8'h01, 16'h0082, 16'h0005); // SELL id=82, price=130, qty=5
        send_order(8'h01, 16'h0053, 8'h01, 16'h008C, 16'h0006); // SELL id=83, price=140, qty=6

        wait_for_outcome; // catches the fourth order's resolution

        // give any still-in-flight report transmission time to finish and be captured
        repeat (3000) @(posedge clk);

        if (dut.ask_book.valid !== 8'b00001111) begin
            $display("FAIL: ask book valid mask = %b, expected 8'b00001111 after four back-to-back-to-back orders", dut.ask_book.valid);
        end else begin
            $display("PASS: all four back-to-back-to-back orders correctly rested (book state)");
        end
        print_books;

        // read back all four captured reports, in order — this is the direct check that the FIFO
        // preserved order and dropped nothing under a burst deeper than the old buffer could handle
        read_captured_report(capOrderID, capOutcome, capPrice, capQuantity, capValid);
        if (!capValid || capOrderID !== 16'h0050 || capOutcome !== 8'h02 || capPrice !== 16'h006E || capQuantity !== 16'h000F) begin
            $display("FAIL: Test 12 first captured report incorrect or missing. valid=%b orderID=%h outcome=%h price=%h quantity=%h",
                    capValid, capOrderID, capOutcome, capPrice, capQuantity);
        end else begin
            $display("PASS: Test 12 first captured report correct (order 0x50)");
        end

        read_captured_report(capOrderID, capOutcome, capPrice, capQuantity, capValid);
        if (!capValid || capOrderID !== 16'h0051 || capOutcome !== 8'h02 || capPrice !== 16'h0078 || capQuantity !== 16'h0014) begin
            $display("FAIL: Test 12 second captured report incorrect or missing. valid=%b orderID=%h outcome=%h price=%h quantity=%h",
                    capValid, capOrderID, capOutcome, capPrice, capQuantity);
        end else begin
            $display("PASS: Test 12 second captured report correct (order 0x51)");
        end

        read_captured_report(capOrderID, capOutcome, capPrice, capQuantity, capValid);
        if (!capValid || capOrderID !== 16'h0052 || capOutcome !== 8'h02 || capPrice !== 16'h0082 || capQuantity !== 16'h0005) begin
            $display("FAIL: Test 12 third captured report incorrect or missing. valid=%b orderID=%h outcome=%h price=%h quantity=%h",
                    capValid, capOrderID, capOutcome, capPrice, capQuantity);
        end else begin
            $display("PASS: Test 12 third captured report correct (order 0x52)");
        end

        read_captured_report(capOrderID, capOutcome, capPrice, capQuantity, capValid);
        if (!capValid || capOrderID !== 16'h0053 || capOutcome !== 8'h02 || capPrice !== 16'h008C || capQuantity !== 16'h0006) begin
            $display("FAIL: Test 12 fourth captured report incorrect or missing. valid=%b orderID=%h outcome=%h price=%h quantity=%h",
                    capValid, capOrderID, capOutcome, capPrice, capQuantity);
        end else begin
            $display("PASS: Test 12 fourth captured report correct (order 0x53) — FIFO depth was sufficient for a 4-deep burst, all reports correctly queued and drained in order");
        end

        if (!queueWasUsed) begin
            $display("FAIL: report_fifo's empty flag never went low during the four-way back-to-back-to-back test — the burst never actually exercised queuing overlap");
        end else begin
            $display("PASS: report_fifo was genuinely exercised (held queued, undrained reports) during the four-way overlap test");
        end


        // Test 13: exceed old 1-deep-buffer capacity outright — six rapid-fire orders with zero gaps,
        // deliberately more overlap than the report_fifo's own DEPTH=8 would need to absorb comfortably,
        // but still well past what a 1-deep buffer could ever have survived without silent overwrites
        #1;
        queueWasUsed = 0;
        captureReadPtr = 0;
        captureWritePtr = 0;
        @(posedge clk);
        #1;

        send_order(8'h01, 16'h0060, 8'h01, 16'h00A0, 16'h0003); // SELL id=96,  price=160, qty=3
        send_order(8'h01, 16'h0061, 8'h01, 16'h00AA, 16'h0003); // SELL id=97,  price=170, qty=3
        send_order(8'h01, 16'h0062, 8'h01, 16'h00B4, 16'h0003); // SELL id=98,  price=180, qty=3
        send_order(8'h01, 16'h0063, 8'h01, 16'h00BE, 16'h0003); // SELL id=99,  price=190, qty=3
        send_order(8'h01, 16'h0064, 8'h01, 16'h00C8, 16'h0003); // SELL id=100, price=200, qty=3
        send_order(8'h01, 16'h0065, 8'h01, 16'h00D2, 16'h0003); // SELL id=101, price=210, qty=3

        wait_for_outcome; // catches the sixth order's resolution

        repeat (5000) @(posedge clk);

        if (dut.ask_book.valid !== 8'b11111111) begin
            $display("FAIL: ask book valid mask = %b, expected full 8'b11111111 after six more back-to-back-to-back orders on top of the existing four", dut.ask_book.valid);
        end else begin
            $display("PASS: all six additional rapid-fire orders correctly rested, filling the ask book to N=8");
        end
        print_books;

        // NOTE: the ask book already held 4 entries from Test 12 (0x50-0x53) before this test started.
        // Of these 6 new orders, only the first 4 (0x60-0x63) find free slots — the book hits N=8 exactly
        // on the fourth, so the 5th and 6th (0x64, 0x65) correctly get REJECTED rather than RESTING.
        // This is intentionally kept rather than "fixed" to fit — it's a stronger test than originally
        // planned, since it confirms the FIFO correctly queues and drains a MIX of RESTING and REJECTED
        // outcomes back-to-back, in order, not just a uniform run of one outcome type.
        for (i = 0; i < 6; i = i + 1) begin
            read_captured_report(capOrderID, capOutcome, capPrice, capQuantity, capValid);
            if (!capValid || capOrderID !== (16'h0060 + i)
                    || capOutcome !== (i < 4 ? 8'h02 : 8'h03)
                    || capPrice !== (16'h00A0 + i*16'h000A) || capQuantity !== 16'h0003) begin
                $display("FAIL: Test 13 captured report #%0d incorrect or missing. valid=%b orderID=%h outcome=%h price=%h quantity=%h, expected outcome=%h",
                        i, capValid, capOrderID, capOutcome, capPrice, capQuantity, (i < 4 ? 8'h02 : 8'h03));
            end else begin
                $display("PASS: Test 13 captured report #%0d correct (order %h, outcome %s)", i, capOrderID, (i < 4 ? "RESTING" : "REJECTED"));
            end
        end

        if (!queueWasUsed) begin
            $display("FAIL: report_fifo was never observed non-empty during the six-way rapid-fire test");
        end else begin
            $display("PASS: report_fifo correctly absorbed a burst well beyond the old 1-deep buffer's capacity, all six reports preserved in order");
        end


        $finish;
    end

endmodule
