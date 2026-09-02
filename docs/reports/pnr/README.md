# Place & Route Reports

Logs from `nextpnr-himbaechel`, run after synthesis (see `../synthesis/`) to
place and route the design on the GW1NR-9C, and to check timing closure
against the board's 27 MHz onboard oscillator.

## Command

```bash
nextpnr-himbaechel --json build/top.json \
  --write build/top_pnr.json \
  --device GW1NR-LV9QN88PC6/I5 \
  --vopt family=GW1N-9C \
  --vopt cst=constraints/tangnano9k.cst \
  --freq 27 \
  --report build/report.json \
  --log docs/reports/pnr/nextpnr_pnr_<date>.log
```

Requires `build/top.json` from the synthesis step to exist first.

## Files

| File | Description |
|---|---|
| `nextpnr_pnr_<date>.log` | Full PNR console output for a given run |