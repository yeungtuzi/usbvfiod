//! End-to-end test of the two-phase hand-over, without a guest.
//!
//! The property this test exists for is the one a live migration depends on:
//! **the incumbent's interrupt line must keep working until the hand-over is
//! committed, and must come back if the migration is cancelled.**
//!
//! A guest is not needed to observe that. usbvfiod's interrupter kicks the newly
//! installed line exactly once whenever a registration replaces the previous one
//! (`UpdateInterruptLine` in `src/device/xhci/interrupter.rs`), so counting the
//! kicks on each peer's eventfd answers "whose line is installed, and did the
//! device actually reach it" directly. Every ownership assertion below is
//! therefore about a real eventfd write, not about a log line.
//!
//! The tests drive the real binaries: they spawn `usbvfiod` and talk to both its
//! vfio-user socket (as a VMM would) and its control socket (as the harness
//! would), so the production code paths are exercised rather than a mock.
//!
//! Run them with:
//!
//! ```text
//! cargo test --test handover_selftest -- --nocapture
//! ```

use std::{
    fs::{self, File},
    io::{ErrorKind, Read},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::{fs::FileExt, net::UnixStream},
    },
    path::PathBuf,
    process::{Child, Command, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

use usbvfiod::hotplug_protocol::handover::{HandoverCommand, HandoverReply, HandoverSnapshot};
use vfio_user::Client;

/// `VFIO_PCI_MSIX_IRQ_INDEX`: usbvfiod only supports a single MSI-X interrupt.
const MSIX_IRQ_INDEX: u32 = 2;
/// PCI BAR0 of the emulated xHCI controller; MMIO below is an offset into it.
const BAR0: u32 = 0;
/// Interrupter 0's runtime registers: RUN_BASE (0x3000) + IR0 (0x20).
const ERSTSZ: u64 = 0x3028;
const ERSTBA: u64 = 0x3030;
/// Guest-physical window these tests publish to usbvfiod.
const GUEST_BASE: u64 = 0x1000_0000;
const MEM_SIZE: u64 = 0x1_0000;
/// Event Ring Segment Table, one segment, at the start of that window.
const ERST_OFFSET: u64 = 0x0000;
const RING_OFFSET: u64 = 0x1000;
const RING_TRBS: u32 = 16;

/// How long to wait for the asynchronous eventfd kick.
const KICK_TIMEOUT: Duration = Duration::from_secs(5);

/// A running `usbvfiod`, killed when the test ends.
struct Server {
    child: Child,
    dir: PathBuf,
    vfio_socket: PathBuf,
    hotplug_socket: PathBuf,
    log: PathBuf,
}

impl Server {
    /// Start usbvfiod with two client slots and the two-phase hand-over enabled.
    fn start(name: &str, extra: &[&str]) -> Self {
        Self::start_with_env(name, extra, &[])
    }

    fn start_with_env(name: &str, extra: &[&str], envs: &[(&str, &str)]) -> Self {
        let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
            .join(format!("handover-selftest-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create scratch dir");
        let vfio_socket = dir.join("vfio.sock");
        let hotplug_socket = dir.join("hotplug.sock");
        let log = dir.join("usbvfiod.log");
        let log_file = File::create(&log).expect("create log file");

        let mut command = Command::new(env!("CARGO_BIN_EXE_usbvfiod"));
        command
            .arg("--no-color")
            .args(["-v", "-v"])
            .args(["--max-clients", "2"]);
        // These tests drive the state machine without a physical USB device, so
        // the "a device must still be attached" condition (A5) cannot hold here;
        // it has its own test below, which switches it on and injects the empty
        // inventory instead.
        if !extra
            .iter()
            .any(|a| a.starts_with("--handover-require-device"))
        {
            command.args(["--handover-require-device", "false"]);
        }
        command
            .arg("--socket-path")
            .arg(&vfio_socket)
            .arg("--hotplug-socket-path")
            .arg(&hotplug_socket)
            .args(extra)
            .stdout(Stdio::from(log_file.try_clone().expect("clone log")))
            .stderr(Stdio::from(log_file));
        for (key, value) in envs {
            command.env(key, value);
        }
        let child = command.spawn().expect("spawn usbvfiod");

        let server = Self {
            child,
            dir,
            vfio_socket,
            hotplug_socket,
            log,
        };
        wait_until(Duration::from_secs(10), || {
            server.vfio_socket.exists() && server.hotplug_socket.exists()
        })
        .expect("usbvfiod did not create both sockets");
        server
    }

    fn log(&self) -> String {
        fs::read_to_string(&self.log).unwrap_or_default()
    }

    /// Wait until the server has logged `needle`.
    ///
    /// Used to synchronise with the interrupter worker: until it has consumed the
    /// event-ring configuration, a newly installed line is recorded but *not*
    /// kicked, and a test that raced with that would see no kick at all.
    fn await_log(&self, needle: &str) {
        assert!(
            wait_until(Duration::from_secs(10), || self.log().contains(needle)).is_ok(),
            "usbvfiod never logged {needle:?}; log was:\n{}",
            self.log()
        );
    }

    /// How often a new interrupt line was installed.
    fn line_installations(&self) -> usize {
        self.log()
            .lines()
            .filter(|line| line.contains("interrupt line installed"))
            .count()
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// One vfio-user connection, standing in for a VMM.
struct Peer {
    /// Connection id as usbvfiod reports it, learned from the ownership status.
    id: Option<u64>,
    client: Client,
    /// Interrupt eventfd whose writes count the kicks this peer received.
    efd: File,
    /// Guest memory published to the device.
    memory: File,
}

impl Peer {
    fn connect(server: &Server) -> Self {
        let client = Client::new(&server.vfio_socket).expect("vfio-user handshake");
        Self {
            id: None,
            client,
            efd: eventfd(),
            memory: memfd(MEM_SIZE),
        }
    }

    /// Publish guest memory and configure the event ring.
    ///
    /// Both are device state, not connection state: on a same-host migration the
    /// destination maps the very same memory, which is why the ring stays valid
    /// across the hand-over.
    fn prepare(&mut self) {
        self.publish_memory();
        self.configure_event_ring();
    }

    /// Publish this connection's guest memory to the device.
    ///
    /// Separate from [`Self::configure_event_ring`] because a real VMM does not
    /// order the two against the interrupt registration: measured, Cloud
    /// Hypervisor sends `SetIrqs` and its `DmaMap` 0.3 ms later, so a hand-over
    /// must not depend on having seen the mapping already.
    fn publish_memory(&mut self) {
        self.memory
            .write_all_at(&erst_entry(), ERST_OFFSET)
            .expect("write ERST entry");
        self.client
            .dma_map(0, GUEST_BASE, MEM_SIZE, self.memory.as_raw_fd())
            .expect("dma_map");
    }

    fn configure_event_ring(&mut self) {
        self.write32(ERSTSZ, 1);
        // A 64-bit register, but region writes are at most 32 bits wide, so the
        // high half stays zero and the window lives below 4 GiB.
        self.write32(ERSTBA, GUEST_BASE as u32);
    }

    fn write32(&mut self, offset: u64, value: u32) {
        self.client
            .region_write(BAR0, offset, &value.to_le_bytes())
            .expect("region write");
    }

    /// Register the interrupt line. A registration on a connection that is not
    /// the owner is what the server stages as a hand-over candidate.
    fn register(&mut self) {
        self.client
            .set_irqs(MSIX_IRQ_INDEX, 0, 0, 1, &[self.efd.as_raw_fd()])
            .expect("set_irqs");
    }

    /// Disable the interrupt line: a data-path command only the owner may issue.
    fn disable_interrupts(&mut self) {
        self.client
            .set_irqs(MSIX_IRQ_INDEX, 0, 0, 0, &[])
            .expect("set_irqs(disable)");
    }

    /// Forget the DMA mappings this connection created.
    fn unmap(&mut self) {
        self.client
            .dma_unmap(GUEST_BASE, MEM_SIZE)
            .expect("dma_unmap");
    }

    /// Kicks received since the previous call.
    fn drain_kicks(&mut self) -> u64 {
        let mut buf = [0u8; 8];
        match self.efd.read(&mut buf) {
            Ok(8) => u64::from_ne_bytes(buf),
            Ok(other) => panic!("eventfd read returned {other} bytes"),
            Err(e) if e.kind() == ErrorKind::WouldBlock => 0,
            Err(e) => panic!("eventfd read failed: {e}"),
        }
    }

    /// Assert that the line is installed on this peer by waiting for a kick.
    ///
    /// Returns the number of kicks that arrived, which is one per installation
    /// since the previous drain.
    fn wait_for_kick(&mut self) -> u64 {
        let deadline = Instant::now() + KICK_TIMEOUT;
        loop {
            let kicks = self.drain_kicks();
            if kicks > 0 {
                return kicks;
            }
            assert!(
                Instant::now() < deadline,
                "no interrupt kick arrived within {KICK_TIMEOUT:?}: the line is not installed on this connection"
            );
            sleep(Duration::from_millis(10));
        }
    }

    /// Assert that nothing was delivered to this peer.
    ///
    /// The caller is responsible for having given a kick the chance to arrive.
    fn assert_no_kick(&mut self) {
        sleep(Duration::from_millis(200));
        let kicks = self.drain_kicks();
        assert_eq!(kicks, 0, "the line was disturbed: {kicks} unexpected kicks");
    }

    const fn id(&self) -> u64 {
        self.id.expect("connection id was resolved from the status")
    }

    /// Break the connection as a crashed VMM would.
    fn disconnect(&self) {
        let _ = self.client.shutdown();
    }
}

/// The single event-ring segment table entry these tests use.
fn erst_entry() -> [u8; 16] {
    let mut entry = [0u8; 16];
    entry[0..8].copy_from_slice(&(GUEST_BASE + RING_OFFSET).to_le_bytes());
    entry[8..12].copy_from_slice(&RING_TRBS.to_le_bytes());
    entry
}

/// Register a peer and learn its connection id from `role` in the status.
fn adopt(server: &Server, peer: &mut Peer, role: fn(&HandoverSnapshot) -> Option<u64>) -> u64 {
    let snapshot = status(server);
    let id = role(&snapshot).expect("the peer did not take the expected role");
    peer.id = Some(id);
    id
}

/// Ask the control socket for the current ownership state.
fn status(server: &Server) -> HandoverSnapshot {
    match handover(server, &HandoverCommand::Status) {
        HandoverReply::Ok(body) => HandoverSnapshot::parse(&body),
        HandoverReply::Err { code, detail } => {
            panic!("the server refused a status query: {code}: {detail}")
        }
    }
}

/// Send one hand-over command to the control socket.
fn handover(server: &Server, command: &HandoverCommand) -> HandoverReply {
    let socket =
        UnixStream::connect(&server.hotplug_socket).expect("connect to the control socket");
    command
        .send_over_socket(&socket)
        .expect("send the hand-over command");
    HandoverReply::receive_from_socket(&socket).expect("read the hand-over reply")
}

/// Assert that a command is refused with a specific, stable code.
fn expect_refusal(server: &Server, command: &HandoverCommand, code: &str) {
    match handover(server, command) {
        HandoverReply::Ok(body) => panic!("expected the refusal {code}, but got ok {body}"),
        HandoverReply::Err { code: got, detail } => {
            assert_eq!(got, code, "refused with the wrong code: {detail}");
        }
    }
}

/// Assert that a command succeeds and return the resulting status.
fn expect_ok(server: &Server, command: &HandoverCommand) -> HandoverSnapshot {
    match handover(server, command) {
        HandoverReply::Ok(body) => HandoverSnapshot::parse(&body),
        HandoverReply::Err { code, detail } => panic!("expected ok, but got {code}: {detail}"),
    }
}

/// Poll `condition` until it holds or the timeout expires.
fn wait_until(timeout: Duration, mut condition: impl FnMut() -> bool) -> Result<(), ()> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if condition() {
            return Ok(());
        }
        sleep(Duration::from_millis(10));
    }
    Err(())
}

fn eventfd() -> File {
    // SAFETY: a plain eventfd(2) call with flags that exist on Linux.
    let fd = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
    assert!(
        fd >= 0,
        "eventfd failed: {}",
        std::io::Error::last_os_error()
    );
    // SAFETY: `fd` is a fresh, owned descriptor.
    File::from(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn memfd(size: u64) -> File {
    let name = c"usbvfiod-selftest";
    // SAFETY: a plain memfd_create(2) call; the name outlives the call.
    let fd = unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC) };
    assert!(
        fd >= 0,
        "memfd_create failed: {}",
        std::io::Error::last_os_error()
    );
    // SAFETY: `fd` is a fresh, owned descriptor.
    let file = File::from(unsafe { OwnedFd::from_raw_fd(fd) });
    file.set_len(size).expect("size the memfd");
    file
}

/// Bring up an owner and a prepared candidate, with the owner's line verified.
///
/// Returns `(server, owner, candidate, epoch_at_staging)`.
fn owner_and_candidate(name: &str) -> (Server, Peer, Peer, u64) {
    owner_and_candidate_with(name, &[])
}

/// Same, with extra command-line flags for the server.
fn owner_and_candidate_with(name: &str, extra: &[&str]) -> (Server, Peer, Peer, u64) {
    let server = Server::start(name, extra);
    let mut src = Peer::connect(&server);
    src.prepare();
    server.await_log("event ring segment table is at");
    src.register();
    adopt(&server, &mut src, |s| s.owner);
    let boot_epoch = status(&server).epoch;
    assert_eq!(src.wait_for_kick(), 1, "the boot line must be installed");

    let mut dst = Peer::connect(&server);
    dst.prepare();
    dst.register();
    adopt(&server, &mut dst, |s| s.candidate);
    (server, src, dst, boot_epoch)
}

#[test]
fn staging_a_destination_does_not_disturb_the_owner() {
    let (server, mut src, mut dst, boot_epoch) = owner_and_candidate("staging");

    let staged = status(&server);
    assert_eq!(staged.owner, Some(src.id()));
    assert_eq!(staged.candidate, Some(dst.id()));
    assert_eq!(staged.epoch, boot_epoch, "staging must not move the epoch");
    assert!(!staged.ready);

    // The point of the two-phase hand-over: the destination's registration did
    // not touch the incumbent's line, and the destination did not get one either.
    src.assert_no_kick();
    dst.assert_no_kick();

    // A commit without readiness is refused, and leaves the candidate staged so
    // that the driver can retry instead of having to re-register.
    expect_refusal(
        &server,
        &HandoverCommand::Commit {
            conn: dst.id(),
            epoch: boot_epoch,
        },
        "EPREFLIGHT_NOT_READY",
    );
    let after_refusal = status(&server);
    assert_eq!(after_refusal.candidate, Some(dst.id()));
    assert_eq!(after_refusal.owner, Some(src.id()));
    assert!(!after_refusal.ready);
    src.assert_no_kick();

    // The driver declares the destination ready, and only then the commit takes.
    let ready = expect_ok(&server, &HandoverCommand::Ready { conn: dst.id() });
    assert!(ready.ready);
    let committed = expect_ok(
        &server,
        &HandoverCommand::Commit {
            conn: dst.id(),
            epoch: boot_epoch,
        },
    );
    assert_eq!(committed.owner, Some(dst.id()));
    assert_eq!(committed.prev, Some(src.id()));
    assert_eq!(
        committed.candidate, None,
        "the commit consumes the candidate"
    );
    assert_eq!(committed.epoch, boot_epoch + 1);
    assert_eq!(
        dst.wait_for_kick(),
        1,
        "the device must reach the new owner"
    );
    src.assert_no_kick();
}

#[test]
fn a_destination_that_is_missing_memory_is_refused() {
    let (server, mut src, dst, boot_epoch) = owner_and_candidate("incomplete");
    expect_ok(&server, &HandoverCommand::Ready { conn: dst.id() });
    // Consume the candidate so the incomplete one can take its place.
    expect_ok(
        &server,
        &HandoverCommand::Abort {
            conn: dst.id(),
            reason: "replaced by the incomplete destination".to_owned(),
        },
    );
    assert_eq!(status(&server).candidate, None);
    // usbvfiod serves two clients at a time, as the demo does, so free the slot
    // the aborted destination was using. A connection that ends here has its own
    // id retired and the next connection gets a fresh one, which is what makes
    // the reclaim epoch/identity checks meaningful.
    drop(dst);

    // A connection that handshakes and registers but never publishes the memory
    // the device DMAs into must not be allowed to take over: this is the
    // "the destination is missing something, keep the old environment running"
    // requirement.
    let mut bare = Peer::connect(&server);
    bare.register();
    adopt(&server, &mut bare, |s| s.candidate);
    expect_ok(&server, &HandoverCommand::Ready { conn: bare.id() });
    expect_refusal(
        &server,
        &HandoverCommand::Commit {
            conn: bare.id(),
            epoch: boot_epoch,
        },
        "EPREFLIGHT_A3_DMA_INCOMPLETE",
    );
    let refused = status(&server);
    assert_eq!(refused.owner, Some(src.id()), "the owner must be untouched");
    assert_eq!(refused.epoch, boot_epoch, "the epoch must be untouched");
    assert_eq!(
        refused.candidate,
        Some(bare.id()),
        "the candidate stays staged after a preflight refusal"
    );
    src.assert_no_kick();

    // The driver may still give up on it explicitly, and that is a no-op for the
    // incumbent.
    let aborted = expect_ok(
        &server,
        &HandoverCommand::Abort {
            conn: bare.id(),
            reason: "the destination did not publish guest memory".to_owned(),
        },
    );
    assert_eq!(aborted.candidate, None);
    assert_eq!(aborted.owner, Some(src.id()));
    assert_eq!(aborted.epoch, boot_epoch);
    src.assert_no_kick();
    assert!(
        server
            .log()
            .contains("aborted (the destination did not publish guest memory)"),
        "the abort reason must reach the log"
    );
}

#[test]
fn an_uncommitted_candidate_expires_and_leaves_no_trace() {
    let server = Server::start("timeout", &["--handover-preflight-timeout-ms", "300"]);
    let mut src = Peer::connect(&server);
    src.prepare();
    server.await_log("event ring segment table is at");
    src.register();
    adopt(&server, &mut src, |s| s.owner);
    let boot_epoch = status(&server).epoch;
    assert_eq!(src.wait_for_kick(), 1);

    let mut dst = Peer::connect(&server);
    dst.prepare();
    dst.register();
    adopt(&server, &mut dst, |s| s.candidate);

    // Nobody commits: after the preflight window the candidate is expired, and a
    // late commit is what discovers that.
    sleep(Duration::from_millis(600));
    expect_refusal(
        &server,
        &HandoverCommand::Commit {
            conn: dst.id(),
            epoch: boot_epoch,
        },
        "EPREFLIGHT_TIMEOUT",
    );
    let expired = status(&server);
    assert_eq!(
        expired.candidate, None,
        "the expired candidate must be dropped"
    );
    assert_eq!(
        expired.owner,
        Some(src.id()),
        "expiry must not move the device"
    );
    assert_eq!(expired.epoch, boot_epoch, "expiry must not move the epoch");
    // The incumbent never lost the line, and can still reconfigure it.
    src.assert_no_kick();
    src.register();
    assert_eq!(src.wait_for_kick(), 1, "the incumbent may re-register");
}

#[test]
fn a_committed_handover_can_be_reclaimed_or_falls_back() {
    let (server, mut src, mut dst, boot_epoch) = owner_and_candidate("recovery");
    expect_ok(&server, &HandoverCommand::Ready { conn: dst.id() });
    let committed = expect_ok(
        &server,
        &HandoverCommand::Commit {
            conn: dst.id(),
            epoch: boot_epoch,
        },
    );
    assert_eq!(
        dst.wait_for_kick(),
        1,
        "the device must reach the new owner"
    );
    src.assert_no_kick();

    // A stale epoch may not roll the hand-over back.
    expect_refusal(
        &server,
        &HandoverCommand::Reclaim {
            conn: src.id(),
            epoch: boot_epoch,
        },
        "EEPOCH_MISMATCH",
    );
    // Nor may a connection that is not the previous owner.
    expect_refusal(
        &server,
        &HandoverCommand::Reclaim {
            conn: 7,
            epoch: committed.epoch,
        },
        "ERECLAIM_NOT_PREVIOUS_OWNER",
    );
    assert_eq!(status(&server).owner, Some(dst.id()));

    // Teardown from the connection that no longer owns the device is ignored:
    // this is the E1 defect, and it is now refused with a warning.
    let installations_before = server.line_installations();
    src.disable_interrupts();
    src.unmap();
    let after_teardown = status(&server);
    assert_eq!(
        after_teardown.owner,
        Some(dst.id()),
        "the owner must not be disturbed by stale teardown"
    );
    assert_eq!(after_teardown.epoch, committed.epoch);
    assert_eq!(
        server.line_installations(),
        installations_before,
        "a stale disable must not install another line"
    );
    assert!(
        server
            .log()
            .contains("ignoring IRQ disable from stale vfio-user client"),
        "the stale disable must be refused with a warning"
    );
    assert!(
        server.log().contains("ignoring DMA unmap"),
        "the stale unmap must be refused with a warning"
    );
    // The destination's line is still the live one: the device still reaches it.
    dst.register();
    assert_eq!(
        dst.wait_for_kick(),
        1,
        "the new owner's line must have survived the stale teardown"
    );

    // A reclaim puts the previous owner back, and the device reaches it again.
    let reclaimed = expect_ok(
        &server,
        &HandoverCommand::Reclaim {
            conn: src.id(),
            epoch: committed.epoch,
        },
    );
    assert_eq!(reclaimed.owner, Some(src.id()));
    assert_eq!(reclaimed.prev, None);
    assert_eq!(reclaimed.epoch, committed.epoch + 1);
    assert_eq!(
        src.wait_for_kick(),
        1,
        "the device must reach the reclaimed owner"
    );
    // Free this connection's client slot: the two slots are all usbvfiod serves
    // in the configuration the demo uses.
    drop(dst);

    // The committed owner disappears inside the lease: the device falls back to
    // the previous owner with nobody driving it.
    let mut dying = Peer::connect(&server);
    dying.prepare();
    dying.register();
    adopt(&server, &mut dying, |s| s.candidate);
    expect_ok(&server, &HandoverCommand::Ready { conn: dying.id() });
    let committed = expect_ok(
        &server,
        &HandoverCommand::Commit {
            conn: dying.id(),
            epoch: reclaimed.epoch,
        },
    );
    assert_eq!(committed.owner, Some(dying.id()));
    assert_eq!(dying.wait_for_kick(), 1);
    dying.disconnect();
    drop(dying);
    assert!(
        wait_until(Duration::from_secs(5), || status(&server).owner
            == Some(src.id()))
        .is_ok(),
        "the device must return to the previous owner when the committed owner dies"
    );
    assert_eq!(
        src.wait_for_kick(),
        1,
        "the fallback must install and kick the previous owner's line"
    );
    assert!(
        server
            .log()
            .contains("auto-reclaimed the device for client"),
        "the fallback must be logged"
    );
    assert_eq!(
        status(&server).prev,
        None,
        "the fallback consumes the lease"
    );
}

#[test]
fn the_ownership_guard_is_load_bearing() {
    // Same hand-over, but with the debug-only test hook that disables the
    // ownership guard. Without the guard the departing source's teardown reaches
    // the device, which replaces the new owner's line with the dummy line: the
    // device can then no longer reach anybody. That is the E1 defect, reproduced
    // on demand, and it is why the guard is not merely cosmetic.
    let (server, mut src, mut dst, boot_epoch) = {
        let server =
            Server::start_with_env("no-guard", &[], &[("USBVFIOD_DISABLE_OWNER_GUARD", "1")]);
        let mut src = Peer::connect(&server);
        src.prepare();
        server.await_log("event ring segment table is at");
        src.register();
        adopt(&server, &mut src, |s| s.owner);
        let boot_epoch = status(&server).epoch;
        assert_eq!(src.wait_for_kick(), 1);
        let mut dst = Peer::connect(&server);
        dst.prepare();
        dst.register();
        adopt(&server, &mut dst, |s| s.candidate);
        (server, src, dst, boot_epoch)
    };
    expect_ok(&server, &HandoverCommand::Ready { conn: dst.id() });
    expect_ok(
        &server,
        &HandoverCommand::Commit {
            conn: dst.id(),
            epoch: boot_epoch,
        },
    );
    assert_eq!(dst.wait_for_kick(), 1);
    let installations_before = server.line_installations();

    src.disable_interrupts();
    assert!(
        wait_until(Duration::from_secs(5), || {
            server.line_installations() > installations_before
        })
        .is_ok(),
        "without the guard the stale disable installs the dummy line"
    );
    assert!(
        !server
            .log()
            .contains("ignoring IRQ disable from stale vfio-user client"),
        "the guard was supposed to be disabled in this run"
    );
    // The device is now unreachable: a registration by the owner is the only
    // thing left that can put a line back.
    dst.assert_no_kick();
}

#[test]
fn a_dead_owner_lets_the_next_registration_take_over() {
    // The owner dying with nobody left to serve the device must not leave the
    // device owned by a dead connection: a VMM that reconnects after a failed
    // migration has to get its device back without the controller doing anything.
    let (server, src, mut dst, boot_epoch) = owner_and_candidate("orphan");
    expect_ok(&server, &HandoverCommand::Ready { conn: dst.id() });
    let committed = expect_ok(
        &server,
        &HandoverCommand::Commit {
            conn: dst.id(),
            epoch: boot_epoch,
        },
    );
    assert_eq!(committed.owner, Some(dst.id()));
    assert_eq!(dst.wait_for_kick(), 1);

    // Both connections go away: the source first, so that the destination's
    // death has no previous owner left to fall back to.
    src.disconnect();
    drop(src);
    assert!(
        wait_until(Duration::from_secs(5), || {
            status(&server).owner == Some(dst.id())
        })
        .is_ok(),
        "the destination still owns the device while it is alive"
    );
    dst.disconnect();
    drop(dst);
    assert!(
        wait_until(Duration::from_secs(5), || status(&server).owner.is_none()).is_ok(),
        "a dead owner must not keep the device; status was {:?}",
        status(&server)
    );
    assert!(
        server.log().contains("the device is unowned"),
        "the device becoming unowned must be logged"
    );

    // The next connection to register claims it immediately, as at boot.
    let mut reconnected = Peer::connect(&server);
    reconnected.prepare();
    reconnected.register();
    adopt(&server, &mut reconnected, |s| s.owner);
    assert_eq!(
        status(&server).candidate,
        None,
        "claiming an unowned device must not go through staging"
    );
    assert_eq!(
        reconnected.wait_for_kick(),
        1,
        "the reconnected VMM must get a working line"
    );
}

#[test]
fn a_staged_candidate_is_promoted_when_the_owner_dies() {
    // The other half of the same problem: if the source disappears while the
    // destination is staged, the destination is the only claimant left and has to
    // be able to serve the device.
    let (server, src, mut dst, boot_epoch) = owner_and_candidate("promote");
    assert_eq!(status(&server).epoch, boot_epoch);
    src.disconnect();
    drop(src);
    assert!(
        wait_until(Duration::from_secs(5), || {
            status(&server).owner == Some(dst.id())
        })
        .is_ok(),
        "the staged candidate must be promoted; status was {:?}",
        status(&server)
    );
    let promoted = status(&server);
    assert_eq!(
        promoted.candidate, None,
        "the promotion consumes the candidate"
    );
    assert_eq!(
        promoted.epoch,
        boot_epoch + 1,
        "the promotion moves the epoch"
    );
    assert_eq!(
        dst.wait_for_kick(),
        1,
        "the promoted owner must get a working line"
    );
    assert!(
        server.log().contains("promoted the staged candidate"),
        "the promotion must be logged"
    );
}

#[test]
fn a_candidate_that_cannot_serve_is_not_promoted() {
    // Promotion is an automatic commit, so it has to pass the automatic part of
    // the preflight. A destination that never published the guest memory would
    // not complete a single transfer, and handing it the device because the owner
    // happened to die first would be worse than leaving the device unowned.
    let server = Server::start("promote-refused", &[]);
    let mut src = Peer::connect(&server);
    src.prepare();
    server.await_log("event ring segment table is at");
    src.register();
    adopt(&server, &mut src, |s| s.owner);
    let boot_epoch = status(&server).epoch;
    assert_eq!(src.wait_for_kick(), 1);

    let mut bare = Peer::connect(&server);
    bare.register(); // registered, but no dma_map
    adopt(&server, &mut bare, |s| s.candidate);

    src.disconnect();
    drop(src);
    assert!(
        wait_until(Duration::from_secs(5), || status(&server).owner.is_none()).is_ok(),
        "a candidate that cannot serve the device must not be promoted; status was {:?}",
        status(&server)
    );
    assert!(
        server.log().contains("it failed the preflight"),
        "the refused promotion must say why"
    );
    assert!(
        status(&server).candidate.is_none(),
        "the unusable candidate must be dropped, not left staged for the same refusal"
    );

    // A connection that *can* serve the device gets it, because an unowned device
    // is claimed by the next registration.
    let mut good = Peer::connect(&server);
    good.prepare();
    good.register();
    adopt(&server, &mut good, |s| s.owner);
    assert_eq!(
        good.wait_for_kick(),
        1,
        "the usable connection must get a working line"
    );
    assert_eq!(
        status(&server).epoch,
        boot_epoch + 2,
        "each ownership change moves the epoch"
    );
}

#[test]
fn a_destination_that_publishes_memory_after_registering_is_still_usable() {
    // Measured on real VMs and the reason this test exists: the destination's
    // `DmaMap` arrives *after* its `SetIrqs` (0.3 ms later, with the source still
    // owning the device). A hand-over that evaluated the preflight against a
    // snapshot taken at registration time refused the promotion, left the device
    // unowned, and the destination guest lost its USB stack about 35 s later.
    let server = Server::start("late-map", &[]);
    let mut src = Peer::connect(&server);
    src.prepare();
    server.await_log("event ring segment table is at");
    src.register();
    adopt(&server, &mut src, |s| s.owner);
    let boot_epoch = status(&server).epoch;
    assert_eq!(src.wait_for_kick(), 1);

    let mut late = Peer::connect(&server);
    late.register(); // registers before it has published anything
    adopt(&server, &mut late, |s| s.candidate);
    assert_eq!(
        status(&server).epoch,
        boot_epoch,
        "staging must not move the epoch"
    );

    // The mapping arrives, as a real VMM's does, and only then the owner dies.
    late.publish_memory();
    late.configure_event_ring();
    src.disconnect();
    drop(src);
    assert!(
        wait_until(Duration::from_secs(5), || {
            status(&server).owner == Some(late.id())
        })
        .is_ok(),
        "the candidate must be promoted once it has published the memory; status was {:?}",
        status(&server)
    );
    assert_eq!(
        late.wait_for_kick(),
        1,
        "the promoted destination must get a working line"
    );
}

#[test]
fn a_candidate_without_a_real_eventfd_is_refused() {
    // A6 is "the driver says it is ready"; A4 is "the line it sent can actually
    // signal". A descriptor that is not an eventfd would either never be read by
    // the destination VMM or fail on write, so the hand-over refuses it instead of
    // installing a line that can never fire - and the incumbent keeps its own.
    let server = Server::start("bad-fd", &["--handover-require-device", "false"]);
    let mut src = Peer::connect(&server);
    src.prepare();
    server.await_log("event ring segment table is at");
    src.register();
    adopt(&server, &mut src, |s| s.owner);
    let boot_epoch = status(&server).epoch;
    assert_eq!(src.wait_for_kick(), 1);

    let devnull = File::open("/dev/null").expect("open /dev/null");
    let mut bad = Peer::connect(&server);
    bad.client
        .set_irqs(MSIX_IRQ_INDEX, 0, 0, 1, &[devnull.as_raw_fd()])
        .expect("set_irqs with a non-eventfd descriptor");
    adopt(&server, &mut bad, |s| s.candidate);
    let _ = &bad.client;

    // The commit needs readiness first, and then the descriptor is what fails.
    expect_ok(&server, &HandoverCommand::Ready { conn: bad.id() });
    expect_refusal(
        &server,
        &HandoverCommand::Commit {
            conn: bad.id(),
            epoch: boot_epoch,
        },
        "EPREFLIGHT_A4_EVENTFD",
    );
    let refused = status(&server);
    assert_eq!(refused.owner, Some(src.id()), "the owner must be untouched");
    assert_eq!(refused.epoch, boot_epoch, "the epoch must be untouched");
    src.assert_no_kick();
}

#[test]
fn a_handover_without_an_attached_device_is_refused() {
    // A5: if the device is gone there is nothing to hand over, and the honest
    // answer is a clear refusal rather than a hand-over that leaves the guest on a
    // line no device will ever signal. The inventory is injected because these
    // tests run without a physical USB device.
    let server = Server::start_with_env(
        "no-device",
        &["--handover-require-device", "true"],
        &[("USBVFIOD_INJECT_NO_DEVICE", "1")],
    );
    let mut src = Peer::connect(&server);
    src.prepare();
    server.await_log("event ring segment table is at");
    src.register(); // the boot registration is not gated on a preflight
    adopt(&server, &mut src, |s| s.owner);
    let boot_epoch = status(&server).epoch;
    assert_eq!(src.wait_for_kick(), 1);

    let mut dst = Peer::connect(&server);
    dst.prepare();
    dst.register();
    adopt(&server, &mut dst, |s| s.candidate);
    expect_ok(&server, &HandoverCommand::Ready { conn: dst.id() });
    expect_refusal(
        &server,
        &HandoverCommand::Commit {
            conn: dst.id(),
            epoch: boot_epoch,
        },
        "EPREFLIGHT_A5_DEVICE_GONE",
    );
    assert_eq!(status(&server).owner, Some(src.id()));
    assert_eq!(status(&server).epoch, boot_epoch);
    src.assert_no_kick();
    assert!(
        server
            .log()
            .contains("pretending no USB device is attached"),
        "the injected empty inventory must be visible in the log"
    );
}

#[test]
fn a_reclaim_after_the_lease_is_refused() {
    // The lease bounds the controller's rollback decision: once it has expired,
    // a hand-over that succeeded stays succeeded, so a late actor cannot pull the
    // device back out from under a running destination.
    let (server, mut src, mut dst, boot_epoch) =
        owner_and_candidate_with("lease", &["--handover-lease-ms", "300"]);
    expect_ok(&server, &HandoverCommand::Ready { conn: dst.id() });
    let committed = expect_ok(
        &server,
        &HandoverCommand::Commit {
            conn: dst.id(),
            epoch: boot_epoch,
        },
    );
    assert_eq!(committed.owner, Some(dst.id()));
    assert_eq!(dst.wait_for_kick(), 1);

    sleep(Duration::from_millis(700));
    expect_refusal(
        &server,
        &HandoverCommand::Reclaim {
            conn: src.id(),
            epoch: committed.epoch,
        },
        "ERECLAIM_LEASE_EXPIRED",
    );
    let after = status(&server);
    assert_eq!(after.owner, Some(dst.id()), "the owner must not change");
    assert_eq!(after.epoch, committed.epoch, "the epoch must not change");
    // The destination's line is still the live one.
    dst.register();
    assert_eq!(
        dst.wait_for_kick(),
        1,
        "the destination must keep a working line"
    );
    src.assert_no_kick();
}

#[test]
fn a_candidate_with_a_different_interrupt_vector_is_refused() {
    // B3: the two VMMs must agree about which interrupt vector carries the
    // device. A destination that registers a different range would be signalled
    // through a line its guest driver never installed, so the hand-over refuses
    // it and the incumbent keeps the device.
    let server = Server::start("irq-mismatch", &["--handover-require-device", "false"]);
    let mut src = Peer::connect(&server);
    src.prepare();
    server.await_log("event ring segment table is at");
    src.register();
    adopt(&server, &mut src, |s| s.owner);
    let boot_epoch = status(&server).epoch;
    assert_eq!(src.wait_for_kick(), 1);

    let mut odd = Peer::connect(&server);
    odd.prepare();
    // Same index and count as the source, but a different start vector.
    odd.client
        .set_irqs(MSIX_IRQ_INDEX, 0, 1, 1, &[odd.efd.as_raw_fd()])
        .expect("set_irqs with a different vector");
    adopt(&server, &mut odd, |s| s.candidate);
    expect_ok(&server, &HandoverCommand::Ready { conn: odd.id() });
    expect_refusal(
        &server,
        &HandoverCommand::Commit {
            conn: odd.id(),
            epoch: boot_epoch,
        },
        "EPREFLIGHT_B3_IRQ_MISMATCH",
    );
    assert_eq!(status(&server).owner, Some(src.id()));
    assert_eq!(status(&server).epoch, boot_epoch);
    src.assert_no_kick();
}

#[test]
fn watching_for_a_candidate_is_notified_instead_of_polling() {
    // A candidate exists for a few milliseconds on a real migration, which is
    // shorter than a control round trip, so a controller that polls can miss it
    // and lose its chance to decide. The server waits instead and answers the
    // moment the destination registers.
    let server = Server::start("watch", &["--handover-require-device", "false"]);
    let mut src = Peer::connect(&server);
    src.prepare();
    server.await_log("event ring segment table is at");
    src.register();
    adopt(&server, &mut src, |s| s.owner);

    let watcher = {
        let socket = server.hotplug_socket.clone();
        std::thread::spawn(move || {
            let started = Instant::now();
            let command = HandoverCommand::Watch { timeout_ms: 10_000 };
            let stream = UnixStream::connect(&socket).expect("connect to the control socket");
            command
                .send_over_socket(&stream)
                .expect("send the watch command");
            let reply = HandoverReply::receive_from_socket(&stream).expect("read the reply");
            let elapsed = started.elapsed();
            match reply {
                HandoverReply::Ok(body) => (elapsed, HandoverSnapshot::parse(&body)),
                HandoverReply::Err { code, detail } => panic!("watch refused: {code}: {detail}"),
            }
        })
    };

    // Let the watcher park before the destination shows up.
    sleep(Duration::from_millis(300));
    let mut dst = Peer::connect(&server);
    dst.prepare();
    dst.register();
    adopt(&server, &mut dst, |s| s.candidate);

    let (elapsed, snapshot) = watcher.join().expect("watcher thread");
    assert_eq!(
        snapshot.candidate,
        Some(dst.id()),
        "the watcher must be handed the candidate it was waiting for"
    );
    assert!(
        elapsed < Duration::from_secs(3),
        "the watcher must be woken by the registration, not by its timeout ({elapsed:?})"
    );
    assert!(
        elapsed >= Duration::from_millis(250),
        "the watcher must have parked rather than answered immediately ({elapsed:?})"
    );
}
