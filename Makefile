YOSYS = yosys
NEXTPNR = nextpnr-himbaechel
PACK = gowin_pack
LOADER = openFPGALoader

DEVICE = GW1NR-LV9QN88PC6/I5
FAMILY = GW1N-9C
CST = constraints/tangnano9k.cst
RTL = $(wildcard rtl/*.v)

BUILD = build

.PHONY: all synth pnr pack flash clean

all: flash

synth: $(BUILD)/top.json

pnr: $(BUILD)/top_pnr.json

pack: $(BUILD)/top.fs

$(BUILD)/top.json: $(RTL)
	mkdir -p $(BUILD)
	$(YOSYS) -p "read_verilog rtl/*.v; synth_gowin -top top -json $(BUILD)/top.json"

$(BUILD)/top_pnr.json: $(BUILD)/top.json $(CST)
	$(NEXTPNR) --json $(BUILD)/top.json \
	    --write $(BUILD)/top_pnr.json \
	    --device $(DEVICE) \
	    --vopt family=$(FAMILY) \
	    --vopt cst=$(CST) \
	    --report $(BUILD)/report.json

$(BUILD)/top.fs: $(BUILD)/top_pnr.json
	$(PACK) -d $(FAMILY) -o $(BUILD)/top.fs $(BUILD)/top_pnr.json

flash: $(BUILD)/top.fs
	$(LOADER) -b tangnano9k -f $(BUILD)/top.fs

clean:
	rm -rf $(BUILD)