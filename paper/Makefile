# Build the paper.
#   make        -> main.pdf
#   make clean  -> remove aux files

LATEXMK := latexmk
TARGET  := main

.PHONY: all clean distclean

all: $(TARGET).pdf

$(TARGET).pdf: $(TARGET).tex $(wildcard figures/*.tex) $(wildcard data/*.dat)
	$(LATEXMK) -pdf -interaction=nonstopmode -halt-on-error $(TARGET).tex

clean:
	$(LATEXMK) -c $(TARGET).tex

distclean:
	$(LATEXMK) -C $(TARGET).tex
