`default_nettype none

module top (
    input clk,
    input uart_rx,
    output uart_tx,
    output [5:0] led,
    input btn
);

wire orderFilled, orderResting, orderRejected;
wire wrongMsgType, wrongMsgSide, matchLoopOverrunError;

matching_engine matching_engine_inst (
    .clk(clk),
    .uart_rx_line(uart_rx),
    .uart_tx_line(uart_tx),
    .orderFilled(orderFilled),
    .orderResting(orderResting),
    .orderRejected(orderRejected),
    .wrongMsgType(wrongMsgType),
    .wrongMsgSide(wrongMsgSide),
    .matchLoopOverrunError(matchLoopOverrunError)
);

assign led[0] = ~orderFilled;
assign led[1] = ~orderResting;
assign led[2] = ~orderRejected;
assign led[3] = ~wrongMsgType;
assign led[4] = ~wrongMsgSide;
assign led[5] = ~matchLoopOverrunError;

endmodule
