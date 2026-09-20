# Paper: Keeping a Passed-Through USB Storage Device Alive across Same-Host VM Live Migration

IEEE conference-format paper describing the work in this repository: turning a
single-client vfio-user server (`usbvfiod`) into a multi-client one so that a
USB storage device survives a same-host Cloud Hypervisor live migration.

## Build

```console
$ make                      # -> main.pdf   (IEEEtran, two columns)
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
| `figures/*.tex` | TikZ/PGFPlots sources for the figures |
| `data/*.dat` | numbers behind the plots, taken from real measurements |
| `data/results.tex` | **generated** macros: every number quoted in the evaluation |
| `data/progress_meta.tex` | **generated** macros for the copy-progress figure |
| `update-results.py` | generates `data/results.tex` and `data/runs.dat` from the raw CSVs |
| `extract-progress.py` | generates `data/copy_progress.dat` from a run's guest heartbeats |
| `copyedit.py` | applies the writing-review copy-edit list, refusing on drift |
| `Makefile` | build rules |

## Provenance of every number

Nothing in the evaluation is typed by hand: `main.tex` `\input`s
`data/results.tex`, which `update-results.py` regenerates from the per-run CSVs
of each arm plus the exposure, injection and baseline summaries. A missing input
becomes `?` and a warning, so a half-finished campaign cannot look complete.

```console
$ python3 update-results.py --batch /root/usb-runs \
      --exposure data/handover-exposure.txt \
      --inject /root/usb-inject --replug /root/usb-replug \
      --out data/results.tex
$ python3 extract-progress.py /root/usb-runs/debug-1 --out-dir data
```

| figure / table | source |
|---|---|
| acceptance table | `results-<tag>.csv` for every arm (debug, control, release, kickoff) |
| downtime figure | `data/runs.dat`, from the acceptance arm's CSV |
| copy-progress figure | the guest heartbeat (`copied=` field) of one acceptance run |
| transfer-rate figure | the server's USB packet capture of a fixed run and a pre-fix run |
| injection table | `results-*.csv` of the arms produced by `../guest/injection-suite.sh` |
| naive-baseline numbers | `../guest/summarize-replug.py` over the hotplug runs |

## Reproducing the measurements

The harness lives in `../guest/`; `../guest/campaign-b.sh` documents exactly how
the arms of the round-3 campaign were produced and `../guest/injection-suite.sh`
how the fault-injection arms were. Raw logs, checksums and manifests go to
`../artifacts/`; the packet captures are large and are delivered separately.

Prerequisites that are *not* in this repository, and that a third party needs:

| item | how to get it | why |
|---|---|---|
| Ubuntu 22.04.4 live-server ISO | `guest/build-guest.sh` takes it from `ISO=/path/to/ubuntu-22.04.4-live-server-amd64.iso` | the guest rootfs is unpacked from it; the built `rootfs.img` is gitignored (4 GB) |
| `linux-modules-extra-5.15.0-94-generic` deb | `guest/build-guest.sh` downloads it (`EXTRA_DEB_URL`) | exFAT support is not in the minimal layer |
| `squashfs-tools`, `initramfs-tools-core`, `7z`, `qemu-utils` | distribution packages | unpack the squashfs, rebuild the initrd, mount the image |
| the patched vfio-user crate and a CH built against it | `[patch.crates-io]` in the CH tree points at the fix branch; the repository URL and revision are given in the artefact (withheld here for double-blind review) | the reset-capability fix lives in the VMM's dependency graph |
| a USB stick with a 128 MiB `testfile.bin` | create it and record its MD5 in `guest/testfile.md5` | the workload; the device is `DEVICE=/dev/bus/usb/001/007` by default |
| the raw logs | `/root/usb-runs`, `/root/usb-inject`, `/root/usb-replug` (archived under `../artifacts/`) | not in git; one run's packet capture is ~130 MB |

Known gaps in the evidence: the 199.9 s deadlock measurement and the pre-fix
five-run series predate the round-3 archiving harness, so their raw logs are not
in `../artifacts/`; they are documented in `../docs/DEVLOG_cn.md` and
`../docs/phase0-exp-b-ch-vfio-user-migration_cn.md`. Everything the paper's
evaluation quotes is re-derivable from the archived round-3 runs.

## References

Every reference was checked to exist and to carry the stated title, and each one
used for a specific claim was opened and read for that claim. Reference URLs and
bibliographic details are as verified on 2026-09-20.

## Before submission

- The paper is prepared for **double-blind review**: `main.tex` and
  `abstract_zh.tex` carry an anonymous author block and the repository URL is
  deliberately omitted. Fill in real author/affiliation details only for a
  non-anonymous venue.
- The English paper is the primary artefact; the Chinese abstract mirrors it and
  must be regenerated with the same numbers after any change to the results.
