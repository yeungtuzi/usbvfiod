# Build the paper.
#   make        -> main.pdf
#   make data   -> regenerate data/results.tex + data/runs.dat from raw CSVs
#   make clean  -> remove aux files
#
# The evaluation numbers live in data/results.tex, which is generated from the
# per-run CSVs so that no number is ever typed by hand. It is tracked in git, so
# a fresh clone builds as-is; regenerate it with `make data` after a new batch.
# Point RUNROOT at a batch directory (the one holding results-<tag>.csv) and
# INJECT/REPLUG at the injection and baseline batches.

LATEXMK := latexmk
TARGET  := main
RUNROOT ?= /root/usb-runs
INJECT  ?= /root/usb-inject
REPLUG  ?= /root/usb-replug

.PHONY: all data clean distclean

all: $(TARGET).pdf

$(TARGET).pdf: $(TARGET).tex $(wildcard figures/*.tex) $(wildcard data/*.dat) \
               data/results.tex
	$(LATEXMK) -pdf -interaction=nonstopmode -halt-on-error $(TARGET).tex

# `data` is phony and always regenerates: the inputs live outside the repository
# (the batch dirs), so a file-timestamp prerequisite on update-results.py alone
# made `make data` a silent no-op after a new batch.
.PHONY: data
data:
	python3 update-results.py --batch "$(RUNROOT)" \
	  --exposure data/handover-exposure.txt \
	  --inject "$(INJECT)" --replug "$(REPLUG)" --out data/results.tex

clean:
	$(LATEXMK) -c $(TARGET).tex

distclean:
	$(LATEXMK) -C $(TARGET).tex
