`default_nettype none
`timescale 1ns/1ps

module test_obs;
    
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
    wire [15:0] price [0:N-1];
    wire [15:0] quantity [0:N-1];
    wire [15:0] orderID [0:N-1];
    wire [15:0] seqNum [0:N-1];

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

endmodule