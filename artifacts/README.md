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
expects, so copy them next to the checkout and point the Makefile at them.

```console
$ cp -r artifacts/campaign-B-acceptance /tmp/cb   # acceptance/control/release/kick-off
$ cp -r artifacts/injection-round3      /tmp/inj
$ cp -r artifacts/replug-baseline       /tmp/rp
$ cd paper
$ make data RUNROOT=/tmp/cb INJECT=/tmp/inj REPLUG=/tmp/rp
```

`make data` is phony and always regenerates `data/results.tex` (and
`data/runs.dat`); the exposure macros come from
`data/handover-exposure.txt`, which the same command can rebuild with
`guest/analyze-handover-exposure.py`. A missing batch does not fail the build: the
affected macros become `?` and the script warns.

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
