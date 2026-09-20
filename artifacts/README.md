# Raw run artefacts

This directory holds the verbatim output of every demo/acceptance run: the
guest's own log, the serial console capture, both Cloud Hypervisor logs, the
vfio-user server log with per-transfer tracing, the USB packet capture, and the
migration bookkeeping (`migration.epoch`, `migration.done`). Nothing is filtered,
so every number in the paper can be re-derived from these files.

Layout:

```
artifacts/
  host-load.log                    # /proc/loadavg + running-VM count during the round-1/2 batches
  host-load-campaignB.log          # the same sampler during the round-3 campaign
  campaign-A-fixed-lead/           # round-3 campaign run with the fixed-lead trigger, later superseded
  <batch>/MANIFEST.md              # per-run metrics re-derived from the logs + file inventory
  <batch>/SHA256SUMS               # checksums of every artefact
  <batch>/handover-exposure.txt    # per-run hand-over window width and completions at risk
  <batch>/summary.csv              # machine-readable per-run table (from summarize-batch.py)
  <batch>/<tag>-<n>/               # one directory per run
```

The batches and what each one is for:

| batch | contents | why it exists |
|---|---|---|
| `campaign-A-fixed-lead` | 20 debug + 8 control + 1 release run | the first round-3 campaign. Kept because its fixed wall-clock trigger put the migration at a different point in the copy; the results agree with the corrected campaign, which is a robustness check. |
| campaign B | `/root/usb-runs`: debug 20, control 8, release 8, kick-off 8 | the campaign the paper reports |
| injection | `/root/usb-inject`: dormant-hook, 500 ms and 5 s kick on/off, guard-off | the deterministic mechanism tests |
| naive baseline | `/root/usb-replug`: 3 hotplug detach/re-attach runs | the comparison to the naive alternative |
| accidental trigger | `/root/usb-runs-accidental-trigger` | a campaign whose progress trigger read a stale output file; contains the clearest single lost-interrupt stall (`kickoff-3`) |

Regenerating the paper's numbers from an attachment: the archived batch
directories under `artifacts/` are exactly what `paper/update-results.py --batch`
expects, so point the Makefile at them directly (no copying needed, and note that
`/tmp` is a memory-backed tmpfs on this host — do not stage large data there).

```console
$ cd paper
$ make data RUNROOT=../artifacts/campaign-B-acceptance \
            INJECT=../artifacts/injection-round3 \
            REPLUG=../artifacts/replug-baseline
```

`make data` is phony and always regenerates `data/results.tex` (and
`data/runs.dat`); the exposure macros come from
`data/handover-exposure.txt`, which the same command can rebuild with
`guest/analyze-handover-exposure.py`. A missing batch does not fail the build: the
affected macros become `?` and the script warns.

## Where the packet captures are

The USB captures (`usb.pcap`, ~145 MB per run, 161 files, 20.5 GB in total) are
**not** in this directory: they live on the network share at
`/mnt/mt/usbvfiod-artifacts/<batch>/<run>/usb.pcap`, with their checksums in
`/mnt/mt/usbvfiod-artifacts/SHA256SUMS-pcap`. Each batch directory here has a
`PCAPS.md` pointing at its own subdirectory. Move them back (or to another large
filesystem) with `scripts/archive-pcaps-to-mnt.sh`, which copies before deleting,
de-duplicates, and wraps every access to the share in `timeout` because the
share is served by a VM and a hung CIFS mount sleeps uninterruptibly.

Nothing in the paper's evaluation needs the captures: every number is re-derived
from the text logs that remain here. The `replug-baseline` batch has no captures
at all, because `guest/replug-baseline.sh` does not enable packet capture.

The data is not committed to git (a single run's pcap is ~130 MB). Only this
file and `.gitignore` are tracked; the rest is delivered as an attachment.

To reproduce a verdict for any run:

```console
$ guest/verdict.py --guest-log <run>/guest-demo.log \
    --expected-md5 "$(cut -d' ' -f1 guest/testfile.md5)" \
    --migration-epoch "$(cat <run>/migration.epoch)" \
    --migration-done "$(cat <run>/migration.done)" \
    --downtime-ms <n> --max-downtime-ms 2000
```

To re-derive the exposure of a run:

```console
$ guest/analyze-handover-exposure.py <run>
```

To re-derive the naive-baseline and injection summaries:

```console
$ guest/summarize-replug.py /root/usb-replug
$ guest/summarize-injection.py /root/usb-inject
```
