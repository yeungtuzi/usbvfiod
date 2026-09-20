# Paper: Transparent USB Storage Passthrough across Same-Host Live Migration

IEEE conference-format paper describing the work in this repository: turning a
single-client vfio-user server (`usbvfiod`) into a multi-client one so that a
USB storage device survives a same-host Cloud Hypervisor live migration.

## Build

```console
$ make                      # -> main.pdf   (IEEEtran, two columns, 7 pages)
$ xelatex abstract_zh.tex   # -> abstract_zh.pdf (Chinese abstract)
```

`make` needs `texlive-latex-*`, `texlive-pictures` (TikZ/PGFPlots) and
`texlive-publishers` (IEEEtran). The Chinese abstract additionally needs
`texlive-xetex` and `texlive-lang-chinese` (xeCJK/ctex).

## Layout

| path | content |
|---|---|
| `main.tex` | the paper |
| `abstract_zh.tex` | Chinese abstract (separate PDF, for a Chinese defence) |
| `figures/*.tex` | TikZ/PGFPlots sources for Figures 1-5 |
| `data/*.dat` | numbers behind the plots, taken from real measurements |
| `Makefile` | build rules |

## Provenance of the figures

Every number in the paper comes from a real run; nothing is illustrative.

| figure | source |
|---|---|
| Fig. 3 downtime | `data/runs.dat` — the ten acceptance runs |
| Fig. 4 copy progress | the guest's own `dd` output in `/root/demo.log` of the representative run |
| Fig. 5 transfer rate | the vfio-user server packet capture (`usb.pcap`) of one successful run and of the pre-fix run that stalled |

Raw evidence for the runs is kept in `../docs/DEVLOG_cn.md` (D7-D9) and the
harness that produces it is `../guest/usb-migration-demo.sh`.

## References

Every reference was checked to exist and to carry the stated title; the Intel
xHCI and USB Bulk-Only Transport specifications and the Linux Symposium 2007
KVM paper were additionally opened and their first page read. Reference URLs
and bibliographic details are as verified on 2026-09-20.

## Before submission

- Replace the placeholder author and institution fields in `main.tex` and
  `abstract_zh.tex`.
- The English paper is the primary artefact; the Chinese abstract mirrors it.
- If the paper is submitted to a venue that requires double-blind review,
  remove the author block entirely.
