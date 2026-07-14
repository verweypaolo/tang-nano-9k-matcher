`default_nettype none
`timescale 1ns/1ps

module test_order_book_side_bid;
    
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

    // reusable printing task
    task print_book;
        integer k;
        begin
            $display("---- Book contents ----");
            for (k = 0; k < N; k = k + 1) begin
                if (valid[k]) begin
                    $display("  slot %0d: price=%h qty=%h orderID=%h seqNum=%h",
                            k, price[k*16 +: 16], quantity[k*16 +: 16],
                            orderID[k*16 +: 16], seqNum[k*16 +: 16]);
                end else begin
                    $display("  slot %0d: (empty)", k);
                end
            end
            $display("------------------------");
        end
    endtask

    // reusable insertion task
    task do_insert;
        input [15:0] p;
        input [15:0] q;
        input [15:0] oid;
        input [15:0] sn;
        begin
            @(posedge clk);
            #1;
            insertValid = 1;
            insertPrice = p;
            insertQuantity = q;
            insertOrderID = oid;
            insertSeqNum = sn;

            @(posedge clk);
            @(posedge clk);

            #1;
            insertValid = 0;
        end
    endtask

    // reusable removal task
    task do_remove;
        begin
            @(posedge clk);
            #1;
            removeValid = 1;

            @(posedge clk);
            @(posedge clk);

            #1;
            removeValid = 0;
        end
    endtask

    initial begin
        $dumpfile("order_book_side_bid_tb.vcd"); // output waveform file
        $dumpvars(0, test_order_book_side_bid);    // 0 = dump all levels of hierarchy, starting from this module
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


        // Test 3: insert into empty book
        @(posedge clk);
        #1;
        insertValid = 1;
        insertPrice = 16'h0064;
        insertQuantity = 16'h000A;
        insertOrderID = 16'h0001;
        insertSeqNum = 16'h0000;

        @(posedge clk); // let edge register
        @(posedge clk); // insertion

        #1;
        insertValid = 0;

        if (valid !== 8'b00000001) begin
            $display("FAIL: valid mask = %b, expected 8'b00000001 after first insert", valid);
        end else if (price[0*16 +: 16] !== 16'h0064 || quantity[0*16 +: 16] !== 16'h000A
                    || orderID[0*16 +: 16] !== 16'h0001 || seqNum[0*16 +: 16] !== 16'h0000) begin
            $display("FAIL: slot 0 fields incorrect after empty-book insert");
        end else if (insertFullError === 1 || removeEmptyError === 1 || simultaneousOpError === 1) begin
            $display("FAIL: an error flag was incorrectly asserted during a valid insert");
        end else begin
            $display("PASS: insert into empty book landed correctly in slot 0");
        end
        print_book;


        // Test 4a: insert a second entry (lower price - should land after slot 0)
        @(posedge clk);
        #1;
        insertValid = 1;
        insertPrice = 16'h0032;      // 50 — lower price, should sort after 100
        insertQuantity = 16'h0005;
        insertOrderID = 16'h0002;
        insertSeqNum = 16'h0001;

        @(posedge clk);
        @(posedge clk);

        #1;
        insertValid = 0;

        if (valid !== 8'b00000011) begin
            $display("FAIL: valid mask = %b, expected 8'b00000011 after second insert", valid);
        end else if (price[0*16 +: 16] !== 16'h0064 || price[1*16 +: 16] !== 16'h0032) begin
            $display("FAIL: sort order incorrect after second insert. slot0=%h slot1=%h",
                    price[0*16 +: 16], price[1*16 +: 16]);
        end else begin
            $display("PASS: second insert correctly appended after slot 0");
        end
        print_book;

        // Test 4b: insert a price strictly between the two existing entries — forces a real shift
        @(posedge clk);
        #1;
        insertValid = 1;
        insertPrice = 16'h004B;      // 75 — belongs between 100 and 50
        insertQuantity = 16'h0007;
        insertOrderID = 16'h0003;
        insertSeqNum = 16'h0002;

        @(posedge clk);
        @(posedge clk);

        #1;
        insertValid = 0;

        if (valid !== 8'b00000111) begin
            $display("FAIL: valid mask = %b, expected 8'b00000111 after middle insert", valid);
        end else if (price[0*16 +: 16] !== 16'h0064 || orderID[0*16 +: 16] !== 16'h0001) begin
            $display("FAIL: slot 0 disturbed by middle insert. price=%h orderID=%h",
                    price[0*16 +: 16], orderID[0*16 +: 16]);
        end else if (price[1*16 +: 16] !== 16'h004B || orderID[1*16 +: 16] !== 16'h0003) begin
            $display("FAIL: new entry did not land correctly at slot 1. price=%h orderID=%h",
                    price[1*16 +: 16], orderID[1*16 +: 16]);
        end else if (price[2*16 +: 16] !== 16'h0032 || orderID[2*16 +: 16] !== 16'h0002) begin
            $display("FAIL: original second entry did not shift correctly to slot 2. price=%h orderID=%h",
                    price[2*16 +: 16], orderID[2*16 +: 16]);
        end else begin
            $display("PASS: middle insert correctly shifted existing entry and landed at slot 1");
        end
        print_book;


        // Test 5: duplicate price - new order should land AFTER existing same-priced entry
        @(posedge clk);
        #1;
        insertValid = 1;
        insertPrice = 16'h004B;      // 75 - same as existing slot 1
        insertQuantity = 16'h0003;
        insertOrderID = 16'h0004;
        insertSeqNum = 16'h0003;

        @(posedge clk);
        @(posedge clk);

        #1;
        insertValid = 0;

        if (valid !== 8'b00001111) begin
            $display("FAIL: valid mask = %b, expected 8'b00001111 after duplicate-price insert", valid);
        end else if (price[0*16 +: 16] !== 16'h0064 || orderID[0*16 +: 16] !== 16'h0001) begin
            $display("FAIL: slot 0 disturbed by duplicate-price insert");
        end else if (price[1*16 +: 16] !== 16'h004B || orderID[1*16 +: 16] !== 16'h0003) begin
            $display("FAIL: original price-75 entry (orderID 3) lost priority — found price=%h orderID=%h at slot 1",
                    price[1*16 +: 16], orderID[1*16 +: 16]);
        end else if (price[2*16 +: 16] !== 16'h004B || orderID[2*16 +: 16] !== 16'h0004) begin
            $display("FAIL: new price-75 entry (orderID 4) did not land at slot 2. price=%h orderID=%h",
                    price[2*16 +: 16], orderID[2*16 +: 16]);
        end else if (price[3*16 +: 16] !== 16'h0032 || orderID[3*16 +: 16] !== 16'h0002) begin
            $display("FAIL: price-50 entry (orderID 2) did not shift correctly to slot 3. price=%h orderID=%h",
                    price[3*16 +: 16], orderID[3*16 +: 16]);
        end else begin
            $display("PASS: duplicate price correctly resolved by arrival order (orderID 3 kept priority over orderID 4)");
        end
        print_book;


        // Test 6a: fill the remaining 4 slots
        do_insert(16'h0028, 16'h0004, 16'h0005, 16'h0004); // price 40
        do_insert(16'h001E, 16'h0002, 16'h0006, 16'h0005); // price 30
        do_insert(16'h0014, 16'h0006, 16'h0007, 16'h0006); // price 20
        do_insert(16'h000A, 16'h0001, 16'h0008, 16'h0007); // price 10

        if (valid !== 8'b11111111) begin
            $display("FAIL: valid mask = %b, expected full book 8'b11111111 after filling", valid);
        end else begin
            $display("PASS: book correctly filled to N=8 entries");
        end
        print_book;

        // Test 6b: insert into a full book should be rejected and flagged
        do_insert(16'h0001, 16'h0001, 16'h0009, 16'h0008); // arbitrary — should never be accepted

        if (insertFullError !== 1) begin
            $display("FAIL: insertFullError not asserted when inserting into a full book");
        end else if (valid !== 8'b11111111) begin
            $display("FAIL: valid mask changed despite full-book rejection. valid=%b", valid);
        end else if (orderID[7*16 +: 16] !== 16'h0008) begin
            $display("FAIL: slot 7 (last legitimate entry) was disturbed by the rejected insert. orderID=%h",
                    orderID[7*16 +: 16]);
        end else begin
            $display("PASS: insertFullError correctly asserted, book state unchanged");
        end
        print_book;


        // Test 7: remove from a full book - top entry (100, id1) should be removed, everything shifts up
        do_remove;

        if (valid !== 8'b01111111) begin
            $display("FAIL: valid mask = %b, expected 8'b01111111 after first removal", valid);
        end else if (price[0*16 +: 16] !== 16'h004B || orderID[0*16 +: 16] !== 16'h0003) begin
            $display("FAIL: slot 0 after removal = price=%h orderID=%h, expected price=0x4B orderID=0x3",
                    price[0*16 +: 16], orderID[0*16 +: 16]);
        end else if (price[6*16 +: 16] !== 16'h000A || orderID[6*16 +: 16] !== 16'h0008) begin
            $display("FAIL: slot 6 after shift = price=%h orderID=%h, expected price=0x0A orderID=0x8",
                    price[6*16 +: 16], orderID[6*16 +: 16]);
        end else if (insertFullError === 1 || simultaneousOpError === 1 || removeEmptyError === 1) begin
            $display("FAIL: an error flag incorrectly asserted during valid removal");
        end else begin
            $display("PASS: removal correctly removed slot 0 and shifted remaining entries up");
        end
        print_book;

        // Test 8: interleaved insert/remove — book should stay correctly sorted throughout
        do_insert(16'h0046, 16'h0002, 16'h0009, 16'h0008); // price 70 — fills the last empty slot

        if (valid !== 8'b11111111) begin
            $display("FAIL: valid mask = %b, expected full 8'b11111111 after filling insert", valid);
        end else if (price[2*16 +: 16] !== 16'h0046 || orderID[2*16 +: 16] !== 16'h0009) begin
            $display("FAIL: slot 2 after insert = price=%h orderID=%h, expected price=0x46 orderID=0x9",
                    price[2*16 +: 16], orderID[2*16 +: 16]);
        end else begin
            $display("PASS: insert correctly filled last empty slot");
        end
        print_book;

        do_remove; // removes slot0 (75, id3) — book back to 7/8, one empty slot again

        do_insert(16'h003C, 16'h0003, 16'h000A, 16'h0009); // price 60 — fills the newly-opened slot

        if (valid !== 8'b11111111) begin
            $display("FAIL: valid mask = %b, expected full 8'b11111111 after second interleaved insert", valid);
        end else begin
            $display("PASS: interleaved remove-then-insert correctly refilled the book");
        end
        print_book;

        do_remove;
        do_remove;

        if (valid !== 8'b00111111) begin
            $display("FAIL: valid mask = %b, expected 8'b00111111 after two more removes", valid);
        end else begin
            $display("PASS: interleaved sequence completed correctly");
        end
        print_book;


        // Test 9: drain the book fully, then confirm removeEmptyError fires correctly once truly empty
        do_remove;
        do_remove;
        do_remove;
        do_remove;
        do_remove;
        do_remove;

        if (valid !== 8'b00000000) begin
            $display("FAIL: valid mask = %b, expected fully empty 8'b00000000 after draining", valid);
        end else begin
            $display("PASS: book correctly drained to fully empty");
        end
        print_book;

        // now attempt one more remove on the genuinely-empty book
        do_remove;

        if (removeEmptyError !== 1) begin
            $display("FAIL: removeEmptyError not asserted when removing from a book that was previously used and drained");
        end else if (valid !== 8'b0) begin
            $display("FAIL: valid mask changed despite empty-book removal rejection. valid=%b", valid);
        end else begin
            $display("PASS: removeEmptyError correctly asserted after full drain — empty/full transition logic confirmed");
        end
        print_book;

        $finish;
    end

endmodule