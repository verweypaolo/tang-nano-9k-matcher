# Synthesis Reports

Logs from `yosys`, covering both the full top-level design and individual
modules synthesized in isolation. Modules with
sub-instances pull in their dependencies explicitly (see table below);
leaf modules are synthesized alone.

## Top-level (full design)

Produces `build/top.json`, the netlist consumed by place & route
(see `../pnr/`).

```bash
yosys -l docs/reports/synthesis/yosys_top_synth_<date>.log \
  -p "read_verilog rtl/uart_rx.v rtl/uart_tx.v rtl/message_rx.v rtl/message_tx.v rtl/report_fifo.v rtl/order_book_side.v rtl/matching_engine.v rtl/top.v; synth_gowin -top top -json build/top.json; stat"
```

## Per-module checks

No `-json` output — these are elaboration/synthesis sanity checks only,
not inputs to PNR. Modules with sub-instances include their dependencies
in `read_verilog`; leaf modules are read alone.

```bash
# matching_engine (+ dependencies)
yosys -l docs/reports/synthesis/yosys_matching_engine_synth_<date>.log \
  -p "read_verilog rtl/uart_rx.v rtl/uart_tx.v rtl/message_rx.v rtl/message_tx.v rtl/report_fifo.v rtl/order_book_side.v rtl/matching_engine.v; synth_gowin -top matching_engine; stat"

# report_fifo (leaf)
yosys -l docs/reports/synthesis/yosys_report_fifo_synth_<date>.log \
  -p "read_verilog rtl/report_fifo.v; synth_gowin -top report_fifo; stat"

# order_book_side (leaf)
yosys -l docs/reports/synthesis/yosys_order_book_side_synth_<date>.log \
  -p "read_verilog rtl/order_book_side.v; synth_gowin -top order_book_side; stat"

# message_tx (+ dependency)
yosys -l docs/reports/synthesis/yosys_message_tx_synth_<date>.log \
  -p "read_verilog rtl/uart_tx.v rtl/message_tx.v; synth_gowin -top message_tx; stat"

# message_rx (+ dependency)
yosys -l docs/reports/synthesis/yosys_message_rx_synth_<date>.log \
  -p "read_verilog rtl/uart_rx.v rtl/message_rx.v; synth_gowin -top message_rx; stat"

# uart_tx (leaf)
yosys -l docs/reports/synthesis/yosys_uart_tx_synth_<date>.log \
  -p "read_verilog rtl/uart_tx.v; synth_gowin -top uart_tx; stat"

# uart_rx (leaf)
yosys -l docs/reports/synthesis/yosys_uart_rx_synth_<date>.log \
  -p "read_verilog rtl/uart_rx.v; synth_gowin -top uart_rx; stat"
```

## Files

| File | Description |
|---|---|
| `yosys_top_synth_<date>.log` | Full-design synthesis, produces `build/top.json` for PNR |
| `yosys_matching_engine_synth_<date>.log` | matching_engine + dependencies |
| `yosys_report_fifo_synth_<date>.log` | report_fifo (leaf) |
| `yosys_order_book_side_synth_<date>.log` | order_book_side (leaf) |
| `yosys_message_tx_synth_<date>.log` | message_tx + uart_tx |
| `yosys_message_rx_synth_<date>.log` | message_rx + uart_rx |
| `yosys_uart_tx_synth_<date>.log` | uart_tx (leaf) |
| `yosys_uart_rx_synth_<date>.log` | uart_rx (leaf) |