`default_nettype none
`timescale 1ns/1ps

// Testbench for report_fifo.v. Sim-only clock period (10ns) — not tied to
// the real 27MHz system clock, since this module's correctness is purely
// cycle-relative, not timing-critical against the UART baud generator.

module report_fifo_tb;

    localparam DATA_WIDTH = 64;
    localparam DEPTH      = 8;

    reg clk;
    reg rst_n;

    reg                   wr_en;
    reg  [DATA_WIDTH-1:0] wr_data;
    reg                   rd_en;
    wire [DATA_WIDTH-1:0] rd_data;
    wire                  full;
    wire                  empty;
    reg                   clear_full;
    wire                  full_latched;

    integer error_count;
    integer i;

    report_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .wr_data(wr_data),
        .rd_en(rd_en),
        .rd_data(rd_data),
        .full(full),
        .empty(empty),
        .clear_full(clear_full),
        .full_latched(full_latched)
    );

    // clock generation
    initial clk = 0;
    always #5 clk = ~clk;

    // default-low pulses each cycle unless a task explicitly drives them
    initial begin
        wr_en      = 0;
        wr_data    = 0;
        rd_en      = 0;
        clear_full = 0;
        rst_n      = 0;
        error_count = 0;
    end

    // ---- helper tasks -----------------------------------------------

    task do_reset;
        begin
            rst_n = 0;
            wr_en = 0;
            rd_en = 0;
            clear_full = 0;
            @(posedge clk);
            @(posedge clk);
            rst_n = 1;
            @(posedge clk);
        end
    endtask

    // single-cycle write pulse
    task write_one(input [DATA_WIDTH-1:0] data);
        begin
            @(negedge clk);
            wr_en   = 1;
            wr_data = data;
            @(negedge clk);
            wr_en   = 0;
        end
    endtask

    // single-cycle read pulse; caller checks rd_data one cycle later
    task read_one;
        begin
            @(negedge clk);
            rd_en = 1;
            @(negedge clk);
            rd_en = 0;
        end
    endtask

    task check_equal(input [255:0] label, input [63:0] actual, input [63:0] expected);
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s - expected 0x%h, got 0x%h at time %0t", label, expected, actual, $time);
                error_count = error_count + 1;
            end else begin
                $display("PASS: %0s", label);
            end
        end
    endtask

    task check_bit(input [255:0] label, input actual, input expected);
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s - expected %0d, got %0d at time %0t", label, expected, actual, $time);
                error_count = error_count + 1;
            end else begin
                $display("PASS: %0s", label);
            end
        end
    endtask

    // ---- test sequence ------------------------------------------------

    initial begin
        $dumpfile("report_fifo_tb.vcd");
        $dumpvars(0, report_fifo_tb);

        // ---- Test 1: reset state ----
        do_reset;
        check_bit("after reset: empty asserted", empty, 1);
        check_bit("after reset: full deasserted", full, 0);
        check_bit("after reset: full_latched deasserted", full_latched, 0);

        // ---- Test 2: single write then single read, check 1-cycle read latency ----
        write_one(64'hAAAA_1111_2222_3333);
        check_bit("after 1 write: empty deasserted", empty, 0);
        check_bit("after 1 write: full deasserted", full, 0);

        rd_en = 1;
        @(negedge clk);
        rd_en = 0;
        // rd_data is registered: valid on the cycle AFTER rd_en pulses, not the same cycle
        @(negedge clk);
        check_equal("single write/read: rd_data matches", rd_data, 64'hAAAA_1111_2222_3333);
        check_bit("after drain: empty reasserted", empty, 1);

        // ---- Test 3: fill to exactly DEPTH, verify full asserts on the DEPTH-th write ----
        do_reset;
        for (i = 0; i < DEPTH; i = i + 1) begin
            write_one(64'h1000_0000_0000_0000 + i);
        end
        check_bit("after DEPTH writes: full asserted", full, 1);
        // full_latched is a registered sample of the combinational `full` signal,
        // so it lags full by one clock edge by construction — give it that cycle
        // before checking, rather than expecting it same-cycle as full itself.
        @(negedge clk);
        check_bit("after DEPTH writes: full_latched sticky-set", full_latched, 1);

        // ---- Test 4: backpressure — write attempted while full must be silently dropped ----
        write_one(64'hDEAD_BEEF_0000_0000); // should NOT get queued; do_write gated by !full internally
        // drain everything and confirm the dropped write never shows up, and order is preserved
        for (i = 0; i < DEPTH; i = i + 1) begin
            rd_en = 1;
            @(negedge clk);
            rd_en = 0;
            @(negedge clk);
            check_equal("backpressure drain: FIFO order preserved", rd_data, 64'h1000_0000_0000_0000 + i);
        end
        check_bit("after full drain: empty reasserted", empty, 1);

        // ---- Test 5: full_latched stays set after drain (sticky), clears only on clear_full ----
        check_bit("full_latched still set after drain (sticky)", full_latched, 1);
        clear_full = 1;
        @(negedge clk);
        clear_full = 0;
        @(negedge clk);
        check_bit("full_latched cleared after clear_full pulse", full_latched, 0);

        // ---- Test 6: simultaneous write + read leaves count unchanged ----
        do_reset;
        write_one(64'h5555_0000_0000_0001);
        // now queue has 1 entry. Pulse wr_en and rd_en on the same cycle.
        @(negedge clk);
        wr_en   = 1;
        wr_data = 64'h6666_0000_0000_0002;
        rd_en   = 1;
        @(negedge clk);
        wr_en = 0;
        rd_en = 0;
        @(negedge clk);
        check_equal("simultaneous wr+rd: read returns old data (FIFO order)", rd_data, 64'h5555_0000_0000_0001);
        check_bit("simultaneous wr+rd: not empty (net count unchanged)", empty, 0);
        check_bit("simultaneous wr+rd: not full", full, 0);
        // drain remaining entry to confirm it's the second write, not lost/corrupted
        read_one;
        @(negedge clk);
        check_equal("simultaneous wr+rd: second entry intact", rd_data, 64'h6666_0000_0000_0002);
        check_bit("simultaneous wr+rd: empty after final drain", empty, 1);

        // ---- Test 7: pointer wraparound — push/pop past DEPTH boundary multiple times ----
        do_reset;
        for (i = 0; i < 3 * DEPTH; i = i + 1) begin
            // keep queue mostly non-empty by writing then immediately reading,
            // forcing both pointers to wrap around DEPTH repeatedly
            write_one(64'h7000_0000_0000_0000 + i);
            read_one;
            @(negedge clk);
            check_equal("wraparound: data integrity across pointer wrap", rd_data, 64'h7000_0000_0000_0000 + i);
        end
        check_bit("after wraparound loop: empty", empty, 1);
        check_bit("after wraparound loop: not full", full, 0);

        // ---- Test 8: async reset mid-operation clears state immediately ----
        do_reset;
        for (i = 0; i < 4; i = i + 1) begin
            write_one(64'hBEEF_0000_0000_0000 + i);
        end
        check_bit("mid-fill: not empty before async reset", empty, 0);
        rst_n = 0; // assert async reset without waiting for a clock edge
        #1;        // small delta to let the async reset propagate combinationally
        check_bit("async reset: empty asserted immediately", empty, 1);
        check_bit("async reset: full_latched cleared", full_latched, 0);
        rst_n = 1;
        @(negedge clk);

        // ---- summary ----
        if (error_count == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TEST(S) FAILED", error_count);
        end

        $finish;
    end

endmodule

`default_nettype wire