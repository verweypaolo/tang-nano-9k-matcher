# Testbench Reports

Logs from Icarus Verilog simulation runs (`iverilog` + `vvp`), covering
testbenches in `sim/`. 
UART modules were ported over from a different repository and tested there.

## Commands run

```bash
mkdir -p docs/reports/testbench build

# matching_engine (full integration, all RTL)
iverilog -o build/matching_engine_tb.vvp rtl/uart_rx.v rtl/uart_tx.v rtl/message_rx.v rtl/message_tx.v rtl/report_fifo.v rtl/order_book_side.v rtl/matching_engine.v sim/matching_engine_tb.v
vvp build/matching_engine_tb.vvp | tee docs/reports/testbench/matching_engine_tb_<date>.log

# order_book_side — bid side
iverilog -o build/order_book_side_bid_tb.vvp rtl/order_book_side.v sim/order_book_side_bid_tb.v
vvp build/order_book_side_bid_tb.vvp | tee docs/reports/testbench/order_book_side_bid_tb_<date>.log

# order_book_side — ask side
iverilog -o build/order_book_side_ask_tb.vvp rtl/order_book_side.v sim/order_book_side_ask_tb.v
vvp build/order_book_side_ask_tb.vvp | tee docs/reports/testbench/order_book_side_ask_tb_<date>.log

# report_fifo
iverilog -o build/report_fifo_tb.vvp rtl/report_fifo.v sim/report_fifo_tb.v
vvp build/report_fifo_tb.vvp | tee docs/reports/testbench/report_fifo_tb_<date>.log

# message_tx
iverilog -o build/message_tx_tb.vvp rtl/uart_tx.v rtl/uart_rx.v rtl/message_rx.v rtl/message_tx.v sim/message_tx_tb.v
vvp build/message_tx_tb.vvp | tee docs/reports/testbench/message_tx_tb_<date>.log

# message_rx
iverilog -o build/message_rx_tb.vvp rtl/uart_rx.v rtl/message_rx.v sim/message_rx_tb.v
vvp build/message_rx_tb.vvp | tee docs/reports/testbench/message_rx_tb_<date>.log
```

## Files

| File | Description |
|---|---|
| `matching_engine_tb_<date>.log` | Full matching_engine integration testbench |
| `order_book_side_bid_tb_<date>.log` | order_book_side, bid side |
| `order_book_side_ask_tb_<date>.log` | order_book_side, ask side |
| `report_fifo_tb_<date>.log` | report_fifo testbench |
| `message_tx_tb_<date>.log` | message_tx testbench |
| `message_rx_tb_<date>.log` | message_rx testbench |