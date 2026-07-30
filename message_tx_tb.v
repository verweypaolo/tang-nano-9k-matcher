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
    wire [7:0] rxOutcome;
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
        .side(rxOutcome),
        .price(rxPrice),
        .quantity(rxQuantity)
    );

    task wait_for_message_sent;
    // allow full round trip transmission before checking correctness
        integer guard;
        begin
            guard = 0;
            while (!messageSent && !sendWhileBusyError && guard < 2000) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    task wait_for_completion_only;
        // used when we expect sendWhileBusyError to have already fired earlier
        // and we specifically want to confirm the transmission still completes
        integer guard;
        begin
            guard = 0;
            while (!messageSent && guard < 2000) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask


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

    initial begin
        @(posedge clk);
        #1;

        // Test 1: a single report round-trips correctly through message_tx -> uart_tx -> uart_rx -> message_rx
        sendMessageValid = 1;
        msgType = 8'h01;
        orderID = 16'h0064;   // 100
        outcome = 8'h01;      // FILLED
        price = 16'h0032;     // 50
        quantity = 16'h000A;  // 10

        @(posedge clk);
        #1;
        sendMessageValid = 0;

        wait_for_message_sent;

        if (messageSent !== 1) begin
            $display("FAIL: messageSent not asserted after sending a report");
        end else if (sendWhileBusyError === 1) begin
            $display("FAIL: sendWhileBusyError incorrectly asserted during a normal single send");
        end else if (rxMessageReady !== 1) begin
            $display("FAIL: reference receiver did not assert messageReady");
        end else if (rxMsgType !== 8'h01 || rxOrderID !== 16'h0064 || rxOutcome !== 8'h01
                || rxPrice !== 16'h0032 || rxQuantity !== 16'h000A) begin
            $display("FAIL: decoded fields do not match sent report. msgType=%h orderID=%h outcome=%h price=%h quantity=%h",
                    rxMsgType, rxOrderID, rxOutcome, rxPrice, rxQuantity);
        end else if (rxSentinelError === 1 || rxChecksumError === 1 || rxTimeOutError === 1) begin
            $display("FAIL: reference receiver flagged an error decoding a valid transmission");
        end else begin
            $display("PASS: report correctly round-tripped through message_tx and decoded by reference receiver");
        end


        // Test 2: sending while busy should be flagged and ignored, the in-progress transmission must complete undisturbed
        sendMessageValid = 1;
        msgType = 8'h01;
        orderID = 16'h1234;
        outcome = 8'h02;      // RESTING
        price = 16'h5678;
        quantity = 16'h0009;

        @(posedge clk);
        #1;
        sendMessageValid = 0;

        // wait some cycles into the transmission (well before it finishes), then attempt a second transmission
        repeat (20) @(posedge clk);
        #1;

        sendMessageValid = 1;
        msgType = 8'h99;     
        orderID = 16'hFFFF;
        outcome = 8'h03;
        price = 16'hAAAA;
        quantity = 16'hBBBB;

        @(posedge clk);
        #1;
        sendMessageValid = 0;

        wait_for_completion_only;

        if (sendWhileBusyError !== 1) begin
            $display("FAIL: sendWhileBusyError not asserted for a send attempt while busy");
        end else if (messageSent !== 1) begin
            $display("FAIL: messageSent not asserted — original in-progress transmission should still complete");
        end else if (rxMsgType !== 8'h01 || rxOrderID !== 16'h1234 || rxOutcome !== 8'h02
                || rxPrice !== 16'h5678 || rxQuantity !== 16'h0009) begin
            $display("FAIL: decoded fields do not match the ORIGINAL report — stray send may have corrupted transmission. msgType=%h orderID=%h outcome=%h price=%h quantity=%h",
                    rxMsgType, rxOrderID, rxOutcome, rxPrice, rxQuantity);
        end else if (rxChecksumError === 1 || rxSentinelError === 1) begin
            $display("FAIL: reference receiver flagged an error — stray send may have corrupted the frame");
        end else begin
            $display("PASS: stray send-while-busy correctly flagged, original transmission completed undisturbed");
        end


        // Test 3: back-to-back reports, second send immediately once the first fully completes, no artificial gap
        sendMessageValid = 1;
        msgType = 8'h01;
        orderID = 16'h1111;
        outcome = 8'h01;
        price = 16'h2222;
        quantity = 16'h3333;

        @(posedge clk);
        #1;
        sendMessageValid = 0;

        wait_for_message_sent;

        if (messageSent !== 1) begin
            $display("FAIL: messageSent not asserted for first back-to-back report");
        end else if (rxMsgType !== 8'h01 || rxOrderID !== 16'h1111 || rxOutcome !== 8'h01
                || rxPrice !== 16'h2222 || rxQuantity !== 16'h3333) begin
            $display("FAIL: first back-to-back report decoded incorrectly. msgType=%h orderID=%h outcome=%h price=%h quantity=%h",
                    rxMsgType, rxOrderID, rxOutcome, rxPrice, rxQuantity);
        end else begin
            $display("PASS: first back-to-back report correctly sent and decoded");
        end

        // immediately, no gap — send the second report
        sendMessageValid = 1;
        msgType = 8'h02;
        outcome = 8'h03;
        orderID = 16'h4444;
        price = 16'h5555;
        quantity = 16'h6666;

        @(posedge clk);
        #1;
        sendMessageValid = 0;

        wait_for_message_sent;

        if (messageSent !== 1) begin
            $display("FAIL: messageSent not asserted for second back-to-back report");
        end else if (sendWhileBusyError === 1) begin
            $display("FAIL: sendWhileBusyError incorrectly asserted — second send should be accepted cleanly once first completed");
        end else if (rxMsgType !== 8'h02 || rxOrderID !== 16'h4444 || rxOutcome !== 8'h03
                || rxPrice !== 16'h5555 || rxQuantity !== 16'h6666) begin
            $display("FAIL: second back-to-back report decoded incorrectly. msgType=%h orderID=%h outcome=%h price=%h quantity=%h",
                    rxMsgType, rxOrderID, rxOutcome, rxPrice, rxQuantity);
        end else begin
            $display("PASS: second back-to-back report correctly sent and decoded, no gap needed");
        end


        $finish;
    end

endmodule
