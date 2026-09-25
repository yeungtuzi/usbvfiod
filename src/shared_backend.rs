//! Share a single [`XhciBackend`] between several vfio-user client connections.
//!
//! usbvfiod historically served exactly one vfio-user client and exited when it
//! disconnected. During a same-host live migration the destination VMM connects
//! while the source is still connected, which a single-`accept()` server cannot
//! serve: the destination blocks forever in the vfio-user version handshake and
//! the migration never completes.
//!
//! The handshake commands (`Version`, `DeviceGetInfo`, `DeviceGetRegionInfo`,
//! `GetIrqInfo`) never touch the backend, whereas the data path commands
//! (`RegionRead`/`RegionWrite`/`DmaMap`/`DmaUnmap`/`SetIrqs`/`DeviceReset`) do.
//! This wrapper therefore takes the backend lock **per command** instead of per
//! connection, so a second client can complete its handshake while the first
//! one is still connected.
//!
//! # Two-phase hand-over
//!
//! Taking the device by registering an interrupt line is too eager: if the
//! joining VMM then fails, or the migration is cancelled, the incumbent is left
//! holding a line that nobody services. Ownership is therefore staged:
//!
//! * the first connection to register becomes the **owner** immediately (the
//!   boot case, unchanged);
//! * a *second* connection that registers becomes a **candidate**: its file
//!   descriptors are kept, but the backend is not touched, so the owner's line
//!   stays live and the owner may still tear down;
//! * an explicit control-path command **commits** the hand-over, which runs the
//!   preflight, installs the candidate's line and advances the epoch; only then
//!   does the previous owner lose the device;
//! * **abort** drops a candidate (the incumbent is untouched), and **reclaim**
//!   lets the previous owner take the device back within a lease if the
//!   migration is cancelled. Reclaiming does not require the previous VMM to
//!   re-register: its file descriptors were cloned when it registered.
//!
//! The mechanism lives here; the policy (when to commit, abort or reclaim) is
//! driven from the control socket, so the VMM needs no source change.

// The ownership guard is deliberately held across the backend mutation in every
// control-path command: releasing it earlier is exactly the race this module
// exists to close (a departing client tearing down the line a new owner just
// installed). `significant_drop_tightening` asks for the opposite, so it is
// switched off here rather than worked around with no-op `drop` calls.
#![allow(clippy::significant_drop_tightening)]

use std::{
    collections::{HashMap, HashSet},
    fmt,
    fs::File,
    os::fd::AsRawFd,
    sync::{Arc, Mutex, MutexGuard},
    time::{Duration, Instant},
};

use tracing::{info, warn};
use vfio_user::{DmaMapFlags, DmaUnmapFlags, ServerBackend};

use crate::{
    device::xhci::real_device::CompleteRealDevice,
    xhci_backend::{validate_irq_request, XhciBackend},
};

/// Sentinel for "no connection".
const NO_OWNER: u64 = u64::MAX;

/// A registration kept around so the line can be restored without the peer
/// having to register again (the VMM will not).
#[derive(Debug)]
struct Registration {
    index: u32,
    flags: u32,
    start: u32,
    count: u32,
    fds: Vec<File>,
}

impl Registration {
    /// Fresh descriptors for the same eventfd, so the registration can be
    /// installed again without the peer having to send it.
    fn clone_fds(&self) -> std::io::Result<Vec<File>> {
        self.fds.iter().map(File::try_clone).collect()
    }

    /// A full copy, so the registration can be both installed and recorded.
    fn duplicate(&self) -> std::io::Result<Self> {
        Ok(Self {
            index: self.index,
            flags: self.flags,
            start: self.start,
            count: self.count,
            fds: self.clone_fds()?,
        })
    }
}

/// A second connection's registration, staged until the hand-over is committed.
#[derive(Debug)]
struct Candidate {
    id: u64,
    reg: Registration,
    deadline: Instant,
    ready: bool,
}

/// Everything the control path decides, behind one lock.
#[derive(Debug)]
struct Ownership {
    owner: u64,
    /// Previous owner, kept for a lease-bounded reclaim.
    prev: u64,
    epoch: u64,
    committed_at: Option<Instant>,
    candidate: Option<Candidate>,
    owner_reg: Option<Registration>,
    prev_reg: Option<Registration>,
    /// DMA ranges each connection has mapped, for the preflight's coverage check.
    mapped: HashMap<u64, Vec<(u64, u64)>>,
    live: HashSet<u64>,
    lease: Duration,
    preflight_timeout: Duration,
    require_ready: bool,
    auto_reclaim: bool,
    /// Enforce A5 (a device must still be attached).
    require_device: bool,
    /// Number of attached devices as last reported by the control plane.
    ///
    /// `None` means nobody has asked the hot-plug port yet, and then A5 cannot be
    /// evaluated; the device inventory is only observable asynchronously, so the
    /// control plane refreshes it before every hand-over decision.
    device_count: Option<u64>,
    /// Test hook: pretend every connection owns the device.
    disable_owner_guard: bool,
}

/// Errors a control-path hand-over command can return.
#[derive(Debug, PartialEq, Eq)]
pub enum HandoverError {
    NoCandidate,
    WrongCandidate,
    PreflightTimeout,
    NotReady,
    BadEventFd,
    DeviceGone,
    DmaIncomplete,
    IrqMismatch,
    NotPreviousOwner,
    PreviousGone,
    EpochMismatch,
    LeaseExpired,
    Backend(String),
}

impl fmt::Display for HandoverError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoCandidate => write!(f, "no hand-over candidate is staged"),
            Self::WrongCandidate => write!(f, "the named connection is not the candidate"),
            Self::PreflightTimeout => write!(f, "the candidate's preflight timed out"),
            Self::NotReady => write!(f, "the driver has not declared the destination ready"),
            Self::BadEventFd => write!(
                f,
                "the candidate's interrupt eventfd is not usable as an eventfd"
            ),
            Self::DeviceGone => write!(
                f,
                "no USB device is attached any more, so there is nothing to hand over"
            ),
            Self::IrqMismatch => write!(
                f,
                "the candidate registered a different interrupt vector than the owner"
            ),
            Self::DmaIncomplete => {
                write!(f, "the candidate has not mapped the device's DMA ranges")
            }
            Self::NotPreviousOwner => write!(f, "only the previous owner may reclaim"),
            Self::PreviousGone => write!(f, "the previous owner is no longer connected"),
            Self::EpochMismatch => write!(f, "stale epoch; the hand-over moved on"),
            Self::LeaseExpired => write!(f, "the reclaim lease has expired"),
            Self::Backend(e) => write!(f, "backend error: {e}"),
        }
    }
}

impl HandoverError {
    /// Stable, machine-checkable code for the control channel.
    ///
    /// The harness asserts on these rather than on the human-readable text, so
    /// they are part of the control protocol and must not change silently.
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::NoCandidate => "ENO_CANDIDATE",
            Self::WrongCandidate => "EWRONG_CANDIDATE",
            Self::PreflightTimeout => "EPREFLIGHT_TIMEOUT",
            Self::NotReady => "EPREFLIGHT_NOT_READY",
            Self::BadEventFd => "EPREFLIGHT_A4_EVENTFD",
            Self::DeviceGone => "EPREFLIGHT_A5_DEVICE_GONE",
            Self::IrqMismatch => "EPREFLIGHT_B3_IRQ_MISMATCH",
            Self::DmaIncomplete => "EPREFLIGHT_A3_DMA_INCOMPLETE",
            Self::NotPreviousOwner => "ERECLAIM_NOT_PREVIOUS_OWNER",
            Self::PreviousGone => "ERECLAIM_PREV_GONE",
            Self::EpochMismatch => "EEPOCH_MISMATCH",
            Self::LeaseExpired => "ERECLAIM_LEASE_EXPIRED",
            Self::Backend(_) => "EBACKEND",
        }
    }
}

/// Read-only view of the hand-over state, rendered for the control socket.
#[derive(Debug)]
pub struct HandoverStatus {
    pub owner: Option<u64>,
    pub prev: Option<u64>,
    pub candidate: Option<u64>,
    pub epoch: u64,
    pub candidate_ready: bool,
    pub lease_ms: u64,
    pub live: Vec<u64>,
    /// Devices the control plane last reported, if it ever did.
    pub devices: Option<u64>,
    /// Whether A5 (a device must still be attached) is enforced.
    pub require_device: bool,
    /// Whether the driver's readiness declaration is required to commit.
    pub require_ready: bool,
}

impl HandoverStatus {
    #[must_use]
    pub fn render(&self) -> String {
        fn id(v: Option<u64>) -> String {
            v.map_or_else(|| "-".to_owned(), |v| v.to_string())
        }
        format!(
            "owner={} prev={} candidate={} epoch={} ready={} lease_ms={} devices={} require_ready={} require_device={} live={:?}",
            id(self.owner),
            id(self.prev),
            id(self.candidate),
            self.epoch,
            self.candidate_ready,
            self.lease_ms,
            id(self.devices),
            self.require_ready,
            self.require_device,
            self.live,
        )
    }
}

/// State shared by every connection serving the same controller.
#[derive(Debug)]
pub struct SharedBackendState<CRD: CompleteRealDevice> {
    backend: Mutex<XhciBackend<CRD>>,
    ownership: Mutex<Ownership>,
    next_id: std::sync::atomic::AtomicU64,
}

impl<CRD: CompleteRealDevice> SharedBackendState<CRD> {
    #[must_use]
    pub fn new(backend: XhciBackend<CRD>) -> Self {
        Self {
            backend: Mutex::new(backend),
            ownership: Mutex::new(Ownership {
                owner: NO_OWNER,
                prev: NO_OWNER,
                epoch: 0,
                committed_at: None,
                candidate: None,
                owner_reg: None,
                prev_reg: None,
                mapped: HashMap::new(),
                live: HashSet::new(),
                lease: Duration::from_millis(5000),
                preflight_timeout: Duration::from_millis(2000),
                require_ready: true,
                auto_reclaim: true,
                require_device: true,
                device_count: None,
                disable_owner_guard: false,
            }),
            next_id: std::sync::atomic::AtomicU64::new(0),
        }
    }

    /// Configure the hand-over policy from the command line.
    pub fn configure_handover(
        &self,
        lease: Option<Duration>,
        preflight_timeout: Option<Duration>,
        require_ready: Option<bool>,
        auto_reclaim: Option<bool>,
        require_device: Option<bool>,
    ) {
        let mut o = self.lock_ownership();
        if let Some(v) = lease {
            o.lease = v;
        }
        if let Some(v) = preflight_timeout {
            o.preflight_timeout = v;
        }
        if let Some(v) = require_ready {
            o.require_ready = v;
        }
        if let Some(v) = auto_reclaim {
            o.auto_reclaim = v;
        }
        if let Some(v) = require_device {
            o.require_device = v;
        }
    }

    /// Record how many devices the hot-plug port currently holds.
    ///
    /// Called by the control plane, which is the only place that can ask the port
    /// (the inventory is behind the port's async message channel).
    pub fn note_device_inventory(&self, devices: u64) {
        let mut o = self.lock_ownership();
        if o.device_count != Some(devices) {
            info!("device inventory: {devices} attached device(s)");
        }
        o.device_count = Some(devices);
    }

    /// Create a handle for one client connection.
    ///
    /// The id is handed out before the serving thread blocks in `accept`, so a
    /// freshly created handle is a reserved slot rather than a peer. The slot is
    /// recorded as live by [`SharedBackend::touch`] once a client actually sends
    /// something, which keeps the status line honest: an id that shows up there
    /// belongs to a connection that exists.
    pub fn connect(self: &Arc<Self>) -> SharedBackend<CRD> {
        let id = self
            .next_id
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        SharedBackend {
            id,
            state: Arc::clone(self),
            established: false,
        }
    }

    /// Record that a client is connected on this slot.
    fn establish(&self, id: u64) {
        let mut o = self.lock_ownership();
        if o.live.insert(id) {
            info!("vfio-user client {id} connected");
        }
    }

    fn lock_ownership(&self) -> MutexGuard<'_, Ownership> {
        self.ownership
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Forward the hot-plug control handle of the wrapped controller.
    ///
    /// The hand-over commands live on the same control socket as
    /// `attach`/`detach`/`list`, so the two have to be handed out together.
    pub fn hotplug_control(&self) -> crate::device::xhci::port::HotplugControl<CRD> {
        self.lock_backend().hotplug_control()
    }

    /// Called when a connection's command loop ends.
    ///
    /// An owner that disappears must not keep the device, because a dead
    /// connection cannot service an interrupt. Three things can happen, in order
    /// of preference:
    ///
    /// 1. the **previous owner** is still connected: the device goes back to it.
    ///    This is the destination-crashed case and needs no external
    ///    coordination. After a *successful* migration it cannot fire, because
    ///    the connection that disappears then is the previous owner, not the
    ///    owner;
    /// 2. a **candidate is staged**: it is promoted. Somebody has to serve the
    ///    device, and a live connection that has already published memory and an
    ///    interrupt line is the only claimant left. This is the source-died case
    ///    of a successful migration, and promoting makes the hand-over complete
    ///    without the controller;
    /// 3. otherwise the device becomes **unowned**, exactly as at boot, so the
    ///    next registration claims it immediately. A VMM that reconnects after a
    ///    failed migration therefore gets its device back with no controller
    ///    involvement.
    ///
    /// Only the ownership *decision* is made here; the line is installed and the
    /// new owner is kicked, so the guest re-examines the event ring.
    pub fn disconnect(&self, id: u64) {
        let mut o = self.lock_ownership();
        o.live.remove(&id);
        // The owner's DMA ranges outlive its bookkeeping entry: a promoted
        // candidate still has to cover the memory the device was using.
        let owner_ranges = o.mapped.get(&id).cloned().unwrap_or_default();
        o.mapped.remove(&id);
        if o.owner != id {
            return;
        }
        let now = Instant::now();

        // 1. The previous owner takes it back.
        //
        // The lease that bounds the *controller's* reclaim does not apply here:
        // it exists so that a late actor cannot roll back a hand-over that has
        // already succeeded, whereas this path only runs when the owner is
        // provably gone. Refusing to fall back would leave the device owned by a
        // connection that no longer exists, which is strictly worse than handing
        // it to the connection that held it before.
        if o.auto_reclaim && o.prev != NO_OWNER && o.live.contains(&o.prev) {
            let prev = o.prev;
            if let Some(reg) = o.prev_reg.take() {
                match self.install_registration(&reg) {
                    Ok(recorded) => {
                        o.owner = prev;
                        o.prev = NO_OWNER;
                        o.owner_reg = Some(recorded);
                        o.committed_at = Some(now);
                        o.epoch += 1;
                        info!(
                            "auto-reclaimed the device for client {prev} because the owner {id} disconnected (epoch {})",
                            o.epoch
                        );
                        return;
                    }
                    Err(e) => {
                        o.prev_reg = Some(reg);
                        warn!("auto-reclaim failed, falling through to the next option: {e}");
                    }
                }
            }
        }

        // 2. A staged candidate is promoted, but only if it could actually serve
        //    the device: promoting a candidate that has not published the guest
        //    memory would hand the device to a VMM that cannot complete a single
        //    transfer.
        if o.auto_reclaim {
            if let Some(cand) = o.candidate.take() {
                if let Err(e) = preflight_hard(&o, &cand, &owner_ranges) {
                    warn!(
                        "not promoting candidate {}: it failed the preflight ({e}); the device stays unowned",
                        cand.id
                    );
                    o.candidate = None;
                    // fall through to "unowned"
                    return self.make_unowned(o, id);
                }
                match self.install_registration(&cand.reg) {
                    Ok(recorded) => {
                        o.owner = cand.id;
                        o.prev = NO_OWNER;
                        o.prev_reg = None;
                        o.owner_reg = Some(recorded);
                        o.committed_at = Some(now);
                        o.epoch += 1;
                        info!(
                            "promoted the staged candidate {} because the owner {id} disconnected (epoch {})",
                            cand.id, o.epoch
                        );
                        return;
                    }
                    Err(e) => {
                        warn!("promoting the candidate failed, leaving the device unowned: {e}");
                    }
                }
            }
        }

        // 3. Nobody can serve the device.
        self.make_unowned(o, id);
    }

    /// Leave the device with no owner, exactly as at boot.
    fn make_unowned(&self, mut o: MutexGuard<'_, Ownership>, id: u64) {
        o.owner = NO_OWNER;
        o.owner_reg = None;
        o.prev = NO_OWNER;
        o.prev_reg = None;
        o.candidate = None;
        o.committed_at = None;
        o.epoch += 1;
        warn!(
            "the device is unowned (epoch {}): owner connection {id} is gone and no live connection could take it over; the next registration claims it",
            o.epoch
        );
    }

    /// Install a registration by re-issuing `SetIrqs` with cloned descriptors.
    ///
    /// Returns the copy to record as the new owner's registration, so a later
    /// reclaim can install the same line again.
    fn install_registration(&self, reg: &Registration) -> Result<Registration, HandoverError> {
        let backend_error = |e: std::io::Error| HandoverError::Backend(e.to_string());
        let recorded = reg.duplicate().map_err(backend_error)?;
        let fds = reg.clone_fds().map_err(backend_error)?;
        self.lock_backend()
            .set_irqs(reg.index, reg.flags, reg.start, reg.count, fds)
            .map_err(backend_error)?;
        Ok(recorded)
    }

    fn lock_backend(&self) -> MutexGuard<'_, XhciBackend<CRD>> {
        // A panicking client must not take the whole controller down, so recover
        // from a poisoned mutex rather than propagating the panic.
        self.backend
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// `owner`/`prev`/`epoch`/candidate, for the control socket.
    #[must_use]
    pub fn handover_status(&self) -> HandoverStatus {
        let mut o = self.lock_ownership();
        o.expire_candidate(Instant::now());
        self.render_locked(&o)
    }

    fn render_locked(&self, o: &Ownership) -> HandoverStatus {
        let mut live: Vec<u64> = o.live.iter().copied().collect();
        live.sort_unstable();
        HandoverStatus {
            owner: (o.owner != NO_OWNER).then_some(o.owner),
            prev: (o.prev != NO_OWNER).then_some(o.prev),
            candidate: o.candidate.as_ref().map(|c| c.id),
            epoch: o.epoch,
            candidate_ready: o.candidate.as_ref().is_some_and(|c| c.ready),
            lease_ms: u64::try_from(o.lease.as_millis()).unwrap_or(u64::MAX),
            live,
            devices: o.device_count,
            require_device: o.require_device,
            require_ready: o.require_ready,
        }
    }

    /// The driver declares the destination ready; a preflight hard condition.
    pub fn handover_ready(&self, id: u64) -> Result<HandoverStatus, HandoverError> {
        let mut o = self.lock_ownership();
        let expired = o.expire_candidate(Instant::now());
        match o.candidate.as_mut() {
            Some(c) if c.id == id => {
                let first = !c.ready;
                c.ready = true;
                if first {
                    info!("hand-over candidate {id} declared ready");
                }
                Ok(self.render_locked(&o))
            }
            Some(_) => Err(HandoverError::WrongCandidate),
            None if expired == Some(id) => Err(HandoverError::PreflightTimeout),
            None => Err(HandoverError::NoCandidate),
        }
    }

    /// Discard a staged candidate. The incumbent is untouched.
    pub fn handover_abort(&self, id: u64, reason: &str) -> Result<HandoverStatus, HandoverError> {
        let mut o = self.lock_ownership();
        o.expire_candidate(Instant::now());
        match &o.candidate {
            Some(c) if c.id == id => {
                o.candidate = None;
                info!(
                    "hand-over aborted ({reason}): candidate {id} dropped; owner {} keeps the line",
                    o.owner
                );
                Ok(self.render_locked(&o))
            }
            Some(_) => Err(HandoverError::WrongCandidate),
            None => Err(HandoverError::NoCandidate),
        }
    }

    /// Run the preflight and, if it passes, hand the device over atomically.
    ///
    /// `epoch` is the epoch the caller observed in [`Self::handover_status`]; it
    /// guards against an actor that decided to commit before a later hand-over
    /// moved the state on. A repeated commit for the connection that already
    /// owns the device is a no-op that returns the current status, so the command
    /// is idempotent.
    ///
    /// The whole preflight runs while the candidate is still staged, so a refusal
    /// leaves the staged registration in place and the caller may retry. The
    /// candidate is consumed only at the commit point: from there on there is no
    /// failure path that could leave half a hand-over behind, because the only
    /// remaining failure modes are `dup(2)` and an interrupt-registration write,
    /// and both abort before the ownership is touched.
    pub fn handover_commit(&self, id: u64, epoch: u64) -> Result<HandoverStatus, HandoverError> {
        let mut o = self.lock_ownership();
        let now = Instant::now();
        let expired = o.expire_candidate(now);
        if o.candidate.is_none() {
            return if o.owner == id && epoch + 1 == o.epoch {
                Ok(self.render_locked(&o))
            } else if expired == Some(id) {
                Err(HandoverError::PreflightTimeout)
            } else {
                Err(HandoverError::NoCandidate)
            };
        }
        if epoch != o.epoch {
            return Err(HandoverError::EpochMismatch);
        }

        // Preflight. Nothing here mutates the ownership state.
        {
            let cand = o.candidate.as_ref().expect("candidate checked above");
            if cand.id != id {
                return Err(HandoverError::WrongCandidate);
            }
            if o.require_ready && !cand.ready {
                return Err(HandoverError::NotReady);
            }
            let owner_ranges = o.mapped.get(&o.owner).cloned().unwrap_or_default();
            if let Err(e) = preflight_hard(&o, cand, &owner_ranges) {
                info!("hand-over commit refused: candidate {id} failed the preflight ({e})");
                return Err(e);
            }
        }

        // Commit point.
        let cand = o.candidate.take().expect("candidate checked above");
        let backend_error = |e: std::io::Error| HandoverError::Backend(e.to_string());
        let recorded = cand.reg.duplicate().map_err(backend_error)?;
        // This is the moment the line changes; the interrupter worker installs it
        // and re-raises one interrupt after the earlier completion events.
        self.lock_backend()
            .set_irqs(
                cand.reg.index,
                cand.reg.flags,
                cand.reg.start,
                cand.reg.count,
                cand.reg.fds,
            )
            .map_err(backend_error)?;
        let from = o.owner;
        o.prev = from;
        o.prev_reg = o.owner_reg.take();
        o.owner = cand.id;
        o.owner_reg = Some(recorded);
        o.epoch += 1;
        o.committed_at = Some(now);
        info!(
            "hand-over committed: owner {} -> {} (epoch {}); the previous owner may reclaim within {:?}",
            from, cand.id, o.epoch, o.lease
        );
        Ok(self.render_locked(&o))
    }

    /// Put the previous owner back on the device after a failed migration.
    ///
    /// `epoch` is the epoch the caller observed when the hand-over was committed;
    /// a stale value is refused so an old actor cannot roll a later hand-over back.
    pub fn handover_reclaim(&self, id: u64, epoch: u64) -> Result<HandoverStatus, HandoverError> {
        let mut o = self.lock_ownership();
        o.expire_candidate(Instant::now());
        if o.prev == NO_OWNER || o.prev != id {
            return Err(HandoverError::NotPreviousOwner);
        }
        if !o.live.contains(&id) {
            return Err(HandoverError::PreviousGone);
        }
        if epoch != o.epoch {
            return Err(HandoverError::EpochMismatch);
        }
        if o.committed_at.is_none_or(|t| t.elapsed() > o.lease) {
            return Err(HandoverError::LeaseExpired);
        }
        let Some(reg) = o.prev_reg.take() else {
            return Err(HandoverError::NotPreviousOwner);
        };
        let recorded = match self.install_registration(&reg) {
            Ok(recorded) => recorded,
            Err(e) => {
                o.prev_reg = Some(reg);
                return Err(e);
            }
        };
        o.owner = id;
        o.prev = NO_OWNER;
        o.owner_reg = Some(recorded);
        o.epoch += 1;
        info!("reclaimed the device for client {id} (epoch {})", o.epoch);
        Ok(self.render_locked(&o))
    }
}

impl Ownership {
    /// Drop a candidate whose preflight window has elapsed without a commit.
    ///
    /// Expiry is evaluated lazily on every control-path entry and on every
    /// registration attempt, which is enough: nothing observable can happen to
    /// the incumbent before one of those runs. Returns the id of the candidate
    /// that was just dropped, so the caller can answer with a precise error.
    fn expire_candidate(&mut self, now: Instant) -> Option<u64> {
        let c = self.candidate.as_ref()?;
        if now <= c.deadline {
            return None;
        }
        let id = c.id;
        info!(
            "hand-over candidate {id} expired after {:?} without a commit; owner {} keeps the line",
            self.preflight_timeout, self.owner
        );
        self.candidate = None;
        Some(id)
    }
}

/// The part of the preflight that every hand-over has to pass.
///
/// Whether a controller commits the candidate or the server has to promote it
/// because the owner died, the candidate must be able to serve the device: its
/// interrupt eventfd has to be usable, and it must have published at least the
/// memory the device was already DMAing into. The driver's readiness declaration
/// is deliberately *not* part of this: nobody is left to declare it when the
/// owner is gone.
/// The candidate's mappings are read from the live ownership state rather than
/// from a snapshot taken when it registered: a VMM maps the guest memory and
/// *then* activates the device, but the two are not ordered relative to each
/// other (measured: the destination's `DmaMap` arrives 0.3\,ms after its
/// `SetIrqs`, with the source still owning the device). Checking a snapshot would
/// reject a candidate that had in fact published everything.
fn preflight_hard(
    o: &Ownership,
    cand: &Candidate,
    owner_ranges: &[(u64, u64)],
) -> Result<(), HandoverError> {
    if cand.reg.fds.iter().any(|f| !is_eventfd(f)) {
        return Err(HandoverError::BadEventFd);
    }
    if o.require_device && o.device_count == Some(0) {
        return Err(HandoverError::DeviceGone);
    }
    // B3: the destination has to configure the same interrupt vector as the
    // source. A different MSI-X index or vector range means the two VMMs do not
    // agree about the device, and handing it over would signal the guest through
    // a line its driver never installed.
    if let Some(owner) = o.owner_reg.as_ref() {
        if (cand.reg.index, cand.reg.start, cand.reg.count)
            != (owner.index, owner.start, owner.count)
        {
            info!(
                "preflight: candidate {} registered index {} start {} count {}, the owner has index {} start {} count {}",
                cand.id, cand.reg.index, cand.reg.start, cand.reg.count,
                owner.index, owner.start, owner.count
            );
            return Err(HandoverError::IrqMismatch);
        }
    }
    let cand_ranges = o.mapped.get(&cand.id).cloned().unwrap_or_default();
    if !ranges_cover(&cand_ranges, owner_ranges) {
        info!(
            "preflight: candidate {} has published {cand_ranges:?}, the device needs {owner_ranges:?}",
            cand.id
        );
        return Err(HandoverError::DmaIncomplete);
    }
    Ok(())
}

/// True if `file` is an eventfd.
///
/// A vfio-user client hands us a descriptor for its interrupt line; nothing in
/// the protocol says it has to be an eventfd. Anything else either cannot be
/// read by the guest's VMM at all or fails on write, so the hand-over refuses it
/// up front instead of installing a line that can never signal.
///
/// The check reads `/proc/self/fdinfo/<fd>`, which reports `eventfd-count` only
/// for eventfds. `fcntl(F_GETFL)` cannot tell an eventfd from a pipe or a regular
/// file, and a plain `write` probe would have side effects on the descriptor the
/// VMM is about to wait on.
fn is_eventfd(file: &File) -> bool {
    if file.metadata().is_err() {
        return false;
    }
    let info = std::fs::read_to_string(format!("/proc/self/fdinfo/{}", file.as_raw_fd()));
    info.is_ok_and(|text| text.contains("eventfd-count:"))
}

/// True if every range in `needed` is covered by `have`.
fn ranges_cover(have: &[(u64, u64)], needed: &[(u64, u64)]) -> bool {
    needed.iter().all(|&(a, s)| {
        have.iter()
            .any(|&(ha, hs)| ha <= a && a.checked_add(s).is_some_and(|end| end <= ha + hs))
    })
}

/// A single vfio-user client connection onto a shared [`XhciBackend`].
#[derive(Debug)]
pub struct SharedBackend<CRD: CompleteRealDevice> {
    id: u64,
    state: Arc<SharedBackendState<CRD>>,
    /// Whether this slot has already been reported as live.
    established: bool,
}

impl<CRD: CompleteRealDevice> SharedBackend<CRD> {
    fn backend(&self) -> MutexGuard<'_, XhciBackend<CRD>> {
        self.state.lock_backend()
    }

    /// Note that a client is really there before the first command is served.
    ///
    /// Every data-path entry point calls this, so a slot appears in the status as
    /// soon as its connection is more than a pending `accept`.
    fn touch(&mut self) {
        if !self.established {
            self.established = true;
            self.state.establish(self.id);
        }
    }

    /// Test hook (debug builds only): pretend that every connection owns the
    /// device. This deliberately reintroduces the stale-teardown defect so an
    /// injection run can show that the ownership guard is load-bearing instead of
    /// merely plausible. It must never be enabled in a build that is used to
    /// measure the fixed system.
    fn guard_disabled(&self, o: &Ownership) -> bool {
        #[cfg(debug_assertions)]
        if o.disable_owner_guard || std::env::var_os("USBVFIOD_DISABLE_OWNER_GUARD").is_some() {
            return true;
        }
        let _ = o;
        false
    }

    /// True if this connection may issue destructive teardown right now.
    fn owns_device(&self, o: &Ownership) -> bool {
        self.guard_disabled(o) || o.owner == self.id
    }

    /// True when some *other* connection owns the device, so a teardown from
    /// this one would disturb a live hand-over.
    fn is_stale(&self, o: &Ownership) -> bool {
        !self.owns_device(o) && o.owner != NO_OWNER
    }

    #[must_use]
    pub const fn connection_id(&self) -> u64 {
        self.id
    }
}

impl<CRD: CompleteRealDevice> ServerBackend for SharedBackend<CRD> {
    fn region_read(
        &mut self,
        region: u32,
        offset: u64,
        data: &mut [u8],
    ) -> Result<(), std::io::Error> {
        self.touch();
        self.backend().region_read(region, offset, data)
    }

    fn region_write(
        &mut self,
        region: u32,
        offset: u64,
        data: &[u8],
    ) -> Result<(), std::io::Error> {
        self.touch();
        self.backend().region_write(region, offset, data)
    }

    fn dma_map(
        &mut self,
        flags: DmaMapFlags,
        offset: u64,
        address: u64,
        size: u64,
        fd: Option<File>,
    ) -> Result<(), std::io::Error> {
        self.touch();
        // Ownership is taken first and held across the backend call: the lock
        // order is always `ownership` -> `backend`, never the other way round.
        let mut o = self.state.lock_ownership();
        let result = self.backend().dma_map(flags, offset, address, size, fd);
        if result.is_ok() {
            o.mapped.entry(self.id).or_default().push((address, size));
        }
        result
    }

    fn dma_unmap(
        &mut self,
        flags: DmaUnmapFlags,
        address: u64,
        size: u64,
    ) -> Result<(), std::io::Error> {
        self.touch();
        // A departing VMM unmaps the regions it created. If another connection
        // has taken the device over in the meantime, that unmap must not tear
        // down the new owner's mappings. Ownership is checked in the same
        // critical section as the mutation.
        let mut o = self.state.lock_ownership();
        if self.is_stale(&o) {
            warn!(
                "ignoring DMA unmap at {address:#x} from stale vfio-user client {}",
                self.id
            );
            return Ok(());
        }
        let result = self.backend().dma_unmap(flags, address, size);
        if result.is_ok() {
            if let Some(ranges) = o.mapped.get_mut(&self.id) {
                ranges.retain(|&(a, s)| !(a == address && s == size));
            }
        }
        result
    }

    fn reset(&mut self) -> Result<(), std::io::Error> {
        self.touch();
        // A `DeviceReset` is a data-path command that disturbs the device, so a
        // stale client must not be able to reset a device it no longer owns.
        // Before the first registration there is no owner and the reset is
        // allowed: that is part of the boot handshake.
        let o = self.state.lock_ownership();
        if self.is_stale(&o) {
            warn!(
                "ignoring device reset from stale vfio-user client {}",
                self.id
            );
            return Ok(());
        }
        drop(o);
        self.backend().reset()
    }

    fn set_irqs(
        &mut self,
        index: u32,
        flags: u32,
        start: u32,
        count: u32,
        fds: Vec<File>,
    ) -> Result<(), std::io::Error> {
        self.touch();
        let mut o = self.state.lock_ownership();
        o.expire_candidate(Instant::now());

        // An empty fd list means "disable interrupts". Only the current owner
        // may do that; otherwise the source VMM of a finished migration would
        // disable the destination's line.
        if fds.is_empty() {
            if !self.owns_device(&o) {
                warn!(
                    "ignoring IRQ disable from stale vfio-user client {}",
                    self.id
                );
                return Ok(());
            }
            return self.backend().set_irqs(index, flags, start, count, fds);
        }

        // Reject a malformed request before it is staged.
        validate_irq_request(index, count)?;

        // No owner yet: the boot registration takes the device immediately.
        // Re-registration by the current owner is also applied immediately.
        if o.owner == NO_OWNER || o.owner == self.id {
            let cloned: Vec<File> = fds
                .iter()
                .map(File::try_clone)
                .collect::<std::io::Result<_>>()?;
            let result = self.backend().set_irqs(index, flags, start, count, fds);
            if result.is_ok() {
                let first = o.owner == NO_OWNER;
                o.owner = self.id;
                o.owner_reg = Some(Registration {
                    index,
                    flags,
                    start,
                    count,
                    fds: cloned,
                });
                if first {
                    o.epoch += 1;
                    info!(
                        "client {} is the initial owner (epoch {})",
                        self.id, o.epoch
                    );
                }
            }
            return result;
        }

        // A second client: stage the registration, leave the owner's line alone.
        let deadline = Instant::now() + o.preflight_timeout;
        let ready = o
            .candidate
            .as_ref()
            .is_some_and(|c| c.id == self.id && c.ready);
        o.candidate = Some(Candidate {
            id: self.id,
            reg: Registration {
                index,
                flags,
                start,
                count,
                fds,
            },
            deadline,
            ready,
        });
        info!(
            "hand-over candidate: client {} staged (owner {} keeps the line until commit)",
            self.id, o.owner
        );

        // Test hook (debug builds only): hold the reply to the destination's
        // registration for a while. The destination VMM blocks on this reply
        // while it activates the device, so the hook keeps the migration in the
        // switchover window and makes it possible to fail the migration *after*
        // the destination has asked for the device - the case the staging exists
        // for. The owner is not touched while this sleeps.
        #[cfg(debug_assertions)]
        if let Some(ms) = std::env::var("USBVFIOD_INJECT_STAGING_DELAY_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
        {
            warn!(
                "TEST HOOK: delaying the candidate's registration reply by {ms} ms \
                 (USBVFIOD_INJECT_STAGING_DELAY_MS)"
            );
            std::thread::sleep(Duration::from_millis(ms));
        }

        // The preflight window starts when the destination VMM can act on the
        // staging - that is, when this reply is sent - not while usbvfiod is
        // still inside the registration. Otherwise the window would be partly
        // spent before the peer ever learns that it is the candidate.
        let deadline = Instant::now() + o.preflight_timeout;
        if let Some(cand) = o.candidate.as_mut() {
            cand.deadline = deadline;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::ranges_cover;

    #[test]
    fn coverage_requires_the_whole_range() {
        let have = vec![(0x1000, 0x2000)];
        assert!(ranges_cover(&have, &[(0x1000, 0x1000)]));
        assert!(ranges_cover(&have, &[(0x1800, 0x800)]));
        assert!(ranges_cover(&have, &[]));
        // starts before, ends inside: not covered
        assert!(!ranges_cover(&have, &[(0x0800, 0x1000)]));
        // starts inside and ends exactly at the mapping's end: covered
        assert!(ranges_cover(&have, &[(0x2000, 0x1000)]));
        // starts inside and ends one byte past the mapping: not covered
        assert!(!ranges_cover(&have, &[(0x2000, 0x1001)]));
        // disjoint
        assert!(!ranges_cover(&have, &[(0x4000, 0x1000)]));
    }

    #[test]
    fn coverage_spans_several_mappings() {
        let have = vec![(0x1000, 0x1000), (0x2000, 0x1000)];
        assert!(ranges_cover(&have, &[(0x1000, 0x1000), (0x2000, 0x1000)]));
        // a range crossing both mappings is not itself covered by either
        assert!(!ranges_cover(&have, &[(0x1800, 0x1000)]));
    }
}
