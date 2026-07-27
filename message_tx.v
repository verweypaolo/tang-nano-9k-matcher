`default_nettype none

module message_tx 
#(
    parameter SENTINEL = 8'hAA, // sentinel byte
    parameter BAUD_DIVISOR = 234,
    parameter ACC_INCREMENT = 3,
    parameter ACC_MODULUS = 8
)
(
    input clk,
    output uart_tx_line,

    input sendMessageValid,
    input [7:0] msgTypeIn,
    input [15:0] orderIDIn,
    input [7:0] outcomeIn,
    input [15:0] priceIn,
    input [15:0] quantityIn,

    output reg messageSent,
    output reg txBusy,
    output reg sendWhileBusyError
);

// store local copy of values to work with on sendMessageValid trigger
reg [7:0] msgType;
reg [15:0] orderID;
reg [7:0] outcome;
reg [15:0] price;
reg [15:0] quantity;

wire [7:0] checksum = SENTINEL
                     ^ msgType
                     ^ orderID[15:8]
                     ^ orderID[7:0]
                     ^ outcome
                     ^ price[15:8]
                     ^ price[7:0]
                     ^ quantity[15:8]
                     ^ quantity[7:0];

reg [3:0] mtxState;

reg sendMessageValidPrev;
wire sendMessageValidEdge = sendMessageValid & !sendMessageValidPrev;

localparam MTX_STATE_IDLE = 0;
localparam MTX_STATE_SENTINEL = 1;


initial begin
    msgType = 0;
    orderID = 0;
    outcome = 0;
    price = 0;
    quantity = 0;

    mtxState = 0;
    sendMessageValidPrev = 0;

    messageSent = 0;
    txBusy = 0;
    sendWhileBusyError = 0;
end

always @(posedge clk) begin
    sendMessageValidPrev <= sendMessageValid;
end

always @(posedge clk) begin
    if (sendMessageValidEdge && mtxState != MTX_STATE_IDLE) begin
        sendWhileBusyError <= 1;
    end

    case (mtxState)
        MTX_STATE_IDLE: begin
            messageSent <= 0;
            sendWhileBusyError <= 0;
            if (sendMessageValidEdge) begin
                // latch current message value
                msgType <= msgTypeIn;
                orderID <= orderIDIn;
                outcome <= outcomeIn;
                price <= priceIn;
                quantity <= quantityIn;
                // indicate transmission has started/in progress
                txBusy <= 1;
                // move state
                mtxState <= MTX_STATE_SENTINEL;

            end
        end
    endcase
end

endmodule
