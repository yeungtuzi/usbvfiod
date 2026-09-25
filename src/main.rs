//! Passthrough of individual USB devices using the vfio-user protocol

mod async_runtime;
mod cli;
mod device;
mod dynamic_bus;
mod hotplug_server;
mod memory_segment;
mod one_indexed_array;
mod oneshot_anyhow;
mod shared_backend;
mod xhci_backend;

use std::{
    os::fd::{FromRawFd, OwnedFd},
    sync::Arc,
    thread,
    time::Duration,
};

use anyhow::{Context, Result};
use async_runtime::init_runtime;
use clap::Parser;
use cli::Cli;
use device::{pcap::UsbPcapManager, xhci::real_device::CompleteRealDevice};
use hotplug_server::{run_hotplug_server, LocalDevice};
use shared_backend::SharedBackendState;
use tracing::{debug, error, info, Level};
use tracing_subscriber::FmtSubscriber;
use vfio_user::Server;
use xhci_backend::XhciBackend;

use crate::async_runtime::runtime;

fn main() -> Result<()> {
    let args = Cli::parse();

    let subscriber = FmtSubscriber::builder()
        .with_max_level(match args.verbose {
            0 => Level::INFO,
            1 => Level::DEBUG,
            _ => Level::TRACE,
        })
        .with_ansi(!args.no_color)
        .finish();

    tracing::subscriber::set_global_default(subscriber)
        .context("Failed to set global tracing subscriber")?;

    // Log messages from the log crate as well.
    tracing_log::LogTracer::init()?;

    UsbPcapManager::init(args.pcap_path.clone());

    init_runtime().context("Failed to initialize async runtime")?;
    let runtime = runtime();

    let backend: XhciBackend<LocalDevice> = xhci_backend::XhciBackend::new(runtime.clone())
        .context("Failed to create virtual XHCI controller")?;
    for device in &args.devices {
        let path = device.as_path();
        // if initial device attachment fails, make it clear by panicking
        if let Err(err) = runtime.block_on(backend.add_device_from_path(path, runtime.clone())) {
            panic!("Device attachment failed for {path:?}: {err}");
        }
    }

    let server = Arc::new(match args.server_socket() {
        cli::ServerSocket::Path(socket_path) => {
            // `resettable = false`: usbvfiod must never reset the device on
            // reconnect, which would make the guest re-enumerate (R4).
            Server::new(socket_path, false, backend.irqs(), backend.regions())
                .context("Failed to create vfio-user server")?
        }
        cli::ServerSocket::Fd(fd) => {
            // SAFETY: we have to assume the given fd is valid, there is not much else we can do
            let owned_fd = unsafe { OwnedFd::from_raw_fd(fd) };
            Server::from_owned_fd(owned_fd, false, backend.irqs(), backend.regions())
        }
    });

    // Two-phase ownership hand-over only exists once several vfio-user clients
    // are served at once: with a single client there is nobody to hand over to,
    // and the historical one-shot lifetime is preserved.
    let runner = if args.max_clients > 1 {
        let shared = Arc::new(SharedBackendState::new(backend));
        shared.configure_handover(
            Some(Duration::from_millis(args.handover_lease_ms)),
            Some(Duration::from_millis(args.handover_preflight_timeout_ms)),
            Some(args.handover_require_ready),
            Some(args.handover_auto_reclaim),
            Some(args.handover_require_device),
            Some(args.handover_block_registration),
            Some(args.handover_require_controller),
        );
        info!(
            "two-phase hand-over enabled: preflight timeout {} ms, reclaim lease {} ms, require-ready {}, auto-reclaim {}, require-device {}, bind-registration {}, require-controller {}",
            args.handover_preflight_timeout_ms,
            args.handover_lease_ms,
            args.handover_require_ready,
            args.handover_auto_reclaim,
            args.handover_require_device,
            args.handover_block_registration,
            args.handover_require_controller
        );
        Runner::Multi(shared)
    } else {
        Runner::Single(Box::new(backend))
    };

    if let Some(socket) = args.hotplug_socket() {
        let hotplug_control = match &runner {
            Runner::Single(backend) => backend.hotplug_control(),
            Runner::Multi(shared) => shared.hotplug_control(),
        };
        let handover = match &runner {
            Runner::Single(_) => None,
            Runner::Multi(shared) => Some(Arc::clone(shared)),
        };
        thread::Builder::new()
            .name("hot-attach-socket listener".to_string())
            .spawn(move || run_hotplug_server(socket, hotplug_control, runtime.clone(), handover))
            .unwrap();
    }

    info!("We're up!");

    match runner {
        Runner::Multi(shared) => run_multi_client(server, shared, args.max_clients)?,
        Runner::Single(mut backend) => {
            server
                .run(backend.as_mut())
                .context("Failed to start vfio-user server")?;
        }
    }

    if let Some(hotplug_socket_path) = args.hotplug_socket_path {
        if hotplug_socket_path.exists() {
            let _ = std::fs::remove_file(&hotplug_socket_path);
        }
    }

    Ok(())
}

/// Which serving mode this process runs in.
enum Runner<CRD: CompleteRealDevice> {
    /// Historical behaviour: exactly one vfio-user client, process exits when it
    /// disconnects. No hand-over is possible, so no ownership state exists.
    Single(Box<XhciBackend<CRD>>),
    /// Several clients at once, with two-phase ownership hand-over.
    Multi(Arc<SharedBackendState<CRD>>),
}

/// Serve up to `max_clients` concurrent vfio-user clients.
///
/// The destination VMM of a same-host live migration connects while the source
/// VMM is still connected, so more than one client has to be served at a time.
/// Unlike the single-client path, the process stays alive after the last client
/// disconnects; stop it explicitly (or through systemd socket activation).
fn run_multi_client<CRD: CompleteRealDevice>(
    server: Arc<Server>,
    shared: Arc<SharedBackendState<CRD>>,
    max_clients: usize,
) -> Result<()> {
    let mut handles = Vec::with_capacity(max_clients);

    for index in 0..max_clients {
        let server = Arc::clone(&server);
        let shared = Arc::clone(&shared);
        let handle = thread::Builder::new()
            .name(format!("vfio-user-client-{index}"))
            .spawn(move || {
                loop {
                    let mut shared_backend = shared.connect();
                    let id = shared_backend.connection_id();
                    let result = server.run(&mut shared_backend);
                    // The connection is gone: if it was the committed owner and a
                    // previous owner is still around, this is where the device
                    // goes back (see `SharedBackendState::disconnect`).
                    shared.disconnect(id);
                    if let Err(err) = result {
                        error!("vfio-user connection ended with error: {err}");
                        // Do not spin on a persistently failing listener.
                        thread::sleep(Duration::from_millis(100));
                    } else {
                        debug!("vfio-user client disconnected, accepting the next one");
                    }
                }
            })?;
        handles.push(handle);
    }

    for handle in handles {
        let _ = handle.join();
    }

    Ok(())
}
