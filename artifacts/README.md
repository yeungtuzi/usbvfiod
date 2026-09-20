# Raw run artefacts

This directory holds the verbatim output of every demo/acceptance run: the
guest's own log, the serial console capture, both Cloud Hypervisor logs, the
vfio-user server log with per-transfer tracing, the USB packet capture, and the
migration bookkeeping. Nothing is filtered, so every number in the paper can be
re-derived from these files.

Layout:

```
artifacts/
  host-load.log            # /proc/loadavg and running-VM count, sampled every 5 s during the batches
  <batch>/MANIFEST.md      # per-run metrics re-derived from the logs + file inventory
  <batch>/SHA256SUMS       # checksums of every artefact
  <batch>/summary.csv      # machine-readable per-run table (from summarize-batch.py)
  <batch>/<tag>-<n>/       # one directory per run
```

The data is not committed to git (a single run's pcap is ~130 MB). Only this
file and `.gitignore` are tracked; the rest is delivered as an attachment.

To reproduce a verdict for any run:

```console
$ guest/verdict.py --guest-log artifacts/<batch>/<run>/guest-demo.log \
    --expected-md5 "$(cut -d' ' -f1 guest/testfile.md5)" \
    --migration-epoch "$(cat artifacts/<batch>/<run>/migration.epoch)"
```
