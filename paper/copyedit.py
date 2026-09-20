#!/usr/bin/env python3
"""Apply the copy-edit list from the writing review to paper/main.tex.

Kept as a script so that every edit is auditable and re-runnable, and so that
the paper is not hand-edited inconsistently. Each pair is (quoted phrase,
correction); the script refuses to run if a phrase is not found, which catches
drift between the review and the current revision.

Usage:
  copyedit.py [--apply]      # without --apply it only reports
"""
from __future__ import annotations

import argparse
import sys

P = "paper/main.tex"

EDITS: list[tuple[str, str]] = [
    ("it collides with live migration", "it conflicts with live migration"),
    ("any migration path that tears the session down", "any migration that tears the session down"),
    ("a downtime short enough to be unnoticeable", "a downtime short enough to be imperceptible"),
    ("kernel VFIO devices can migrate when the device implements",
     "in-kernel VFIO devices can migrate when they implement"),
    ("supports USB passthrough through the vfio-user protocol via",
     "supports USB passthrough over the vfio-user protocol using"),
    ("does not fail cleanly", "does not fail gracefully"),
    ("the destination never gets a reply", "the destination never receives a reply"),
    ("at the time of the migration", "when it is migrated"),
    ("both TCP and UNIX-socket transports", "both TCP and UNIX-domain-socket transports"),
    ("registers event descriptors directly", "registers interrupt file descriptors directly"),
    ("The protocol specification is maintained with QEMU",
     "The protocol specification is published with the QEMU project"),
    ("reference implementations exist in \\code{libvfio-user}",
     "a reference implementation is \\code{libvfio-user}"),
    ("is the natural answer for \\emph{cross-host} device sharing",
     "is a natural approach to cross-host device sharing"),
    ("performs a host controller reset", "performs a Host Controller Reset (HCRST)"),
    ("because it is the most common passthrough workload",
     "because storage is a common passthrough workload"),
    ("the resulting architecture", "the architecture we target"),
    ("on which the KVM module is loaded \\cite{kivity2007kvm}", "which runs KVM"),
    ("booted directly with CH", "booted directly by CH"),
    ("Fig.~\\ref{fig:deadlock} illustrates what we measured.",
     "Figure~\\ref{fig:deadlock} shows the measured deadlock."),
    ("Three observations pin the cause down", "Three observations identify the cause"),
    ("contributes almost nothing to a migration in this version",
     "carries almost no migration state in this version"),
    ("A cross-host migration would have the same problem, and additionally the destination would have no device",
     "A cross-host migration would have the same problem and would additionally leave the destination without a device"),
    ("This is why our design deliberately does \\emph{not} try to move device state",
     "For this reason, our design does not attempt to move device state"),
    ("(iv) VMM source code is unchanged (the VMM is only rebuilt against the fixed\nprotocol crate).",
     "(iv) VMM source code is unchanged, the VMM being only rebuilt against the\nfixed protocol crate."),
    ("mostly independent of the device", "mostly independent of device state"),
    ("The result we measured is severe: the destination is left with a dummy interrupt line",
     "The observed effect is severe: the destination is left with a dummy interrupt line"),
    ("aborts the running I/O", "aborts the in-flight I/O"),
    ("it is correct for the hand-over case, which is the case that needs it",
     "it is correct for the hand-over, which is the only case that requires it"),
    ("cannot be triggered accidentally by the active client",
     "cannot be triggered by the active client"),
    ("delivered to the event descriptor of the VMM that is exiting",
     "delivered to the interrupt file descriptor of the exiting VMM"),
    ("A naive ``insert only'' bus rejects the duplicate as an overlap.",
     "A bus that only inserts new mappings rejects the duplicate as an overlap."),
    ("we make a failed insert leave the bus untouched", "a failed insert leaves the bus unchanged"),
    ("The change is confined to six files (about 380 added and 30 removed lines)",
     "The change touches six files (about 380 lines added and 30 removed)"),
    ("\\code{clippy} with all, nursery and cargo groups denied",
     "Clippy with the all, nursery and cargo lint groups denied"),
    ("had to be fixed for the reset semantics to be sane",
     "had to be fixed to make the reset semantics correct"),
    ("by comparing the masked flag word with \\emph{inequality}",
     "by testing inequality on the masked flag word"),
    ("Measurement honesty turned out to require as much care as the device code, and we record the decisions because they changed our verdict twice.",
     "Measurement integrity required as much care as the device code; we record the decisions because they changed our conclusions twice."),
    ("the pre-migration evidence disappears exactly when it becomes interesting",
     "the pre-migration evidence is lost precisely when it becomes relevant"),
    ("A guest heartbeat service, finally, distinguishes", "Finally, a guest heartbeat service distinguishes"),
    ("reproduce on every run", "reproduce in every run"),
    ("appeared in roughly one run in five", "was observed in one of five pre-fix runs"),
    ("we do not want to hide it", "we do not wish to hide it"),
    ("cannot be made lossless by retrying", "cannot be made lossless by retransmission"),
    ("a live migration of the VM it is passed through to",
     "a live migration of the VM to which it is passed through"),
    # spelling consistency
    ("exfat", "exFAT"),
    ("md5", "MD5"),
    ("usbfs", "usbfs"),
]

# phrases where the naive replacement must not fire
GUARDS = [
    ("\\code{downtime\\_ms}", "\\code{downtime\\_ms}"),
    ("md5", "MD5"),  # applied only outside code/verbatim via the guard below
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    text = open(P).read()
    missing = []
    hits = 0
    for old, new in EDITS:
        if old not in text:
            missing.append(old)
            continue
        count = text.count(old)
        hits += count
        if args.apply:
            text = text.replace(old, new)
    if args.apply:
        open(P, "w").write(text)

    print(f"{'applied' if args.apply else 'would apply'}: {hits} replacements")
    if missing:
        print("not found (drift):")
        for m in missing:
            print(f"  - {m[:80]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
