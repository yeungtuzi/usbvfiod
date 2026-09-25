//! Receive runtime commands

use std::{
    fs::File,
    os::unix::net::{UnixListener, UnixStream},
    sync::Arc,
};

use anyhow::{Context, Result};
use nusb::MaybeFuture;
use tokio::runtime;
use tracing::{debug, warn};
use usbvfiod::hotplug_protocol::{
    command::{Command, CommandReceiveError},
    handover::{HandoverCommand, HandoverReply},
    response::Response,
};

use crate::{
    device::xhci::{
        nusb::NusbRealDevice, port::HotplugControl, real_device::CompleteRealDeviceImpl,
    },
    shared_backend::SharedBackendState,
};

/// The device type this binary always builds: hot-plugged `nusb` devices keyed by
/// their bus/device address.
pub type LocalDevice = CompleteRealDeviceImpl<NusbRealDevice, (u8, u8)>;

/// Ownership state shared by the vfio-user connections of one usbvfiod.
pub type LocalSharedState = SharedBackendState<LocalDevice>;

/// Serve control commands until the process ends.
///
/// `handover` is `None` in the historical single-client mode: the two-phase
/// hand-over only exists once several vfio-user clients are served at once, and
/// saying so explicitly is friendlier than a command that silently does nothing.
pub fn run_hotplug_server(
    socket: UnixListener,
    hotplug_control: HotplugControl<LocalDevice>,
    async_runtime: runtime::Handle,
    handover: Option<Arc<LocalSharedState>>,
) {
    loop {
        if let Ok((mut stream, _addr)) = socket.accept() {
            match Command::receive_from_socket(&stream) {
                Ok(command) => {
                    debug!("Received command {:?} on hotplug socket", command);
                    let result = handle_command(
                        command,
                        &mut stream,
                        &hotplug_control,
                        &async_runtime,
                        handover.as_ref(),
                    );
                    if let Err(e) = result {
                        // The error contains all the necessary context
                        warn!("{:?}", e);
                    }
                }
                // A malformed hand-over request still expects one answer line:
                // dropping the connection silently would leave the client
                // waiting for a reply it can never get.
                Err(CommandReceiveError::Handover(e)) => {
                    warn!("Malformed hand-over command on hotplug socket: {e}");
                    let reply = HandoverReply::error("EPARSE", e);
                    if let Err(send) = reply.send_over_socket(&mut stream) {
                        warn!("Failed to answer a malformed hand-over command: {send}");
                    }
                }
                Err(e) => warn!("Error occurred while reading a hotplug command {}", e),
            }
        }
    }
}

fn handle_command(
    command: Command,
    socket: &mut UnixStream,
    hotplug_control: &HotplugControl<LocalDevice>,
    async_runtime: &runtime::Handle,
    handover: Option<&Arc<LocalSharedState>>,
) -> Result<()> {
    match command {
        Command::Attach {
            bus,
            device: dev,
            fd,
        } => handle_attach(bus, dev, fd, socket, hotplug_control, async_runtime)
            .context("Failed to handle attach command")?,
        Command::Detach { bus, device } => {
            handle_detach(bus, device, socket, hotplug_control, async_runtime)
                .context("Failed to handle detach command")?;
        }
        Command::List => {
            let devices = async_runtime.block_on(hotplug_control.list_devices());
            Response::ListFollowing
                .send_device_list(devices, socket)
                .context("Failed to handle list command")?;
        }
        Command::Handover(command) => handle_handover(command, socket, handover)
            .context("Failed to handle hand-over command")?,
    }

    Ok(())
}

/// Apply a two-phase hand-over command and answer on the same connection.
fn handle_handover(
    command: HandoverCommand,
    socket: &mut UnixStream,
    handover: Option<&Arc<LocalSharedState>>,
) -> Result<()> {
    let reply = handover.map_or_else(
        || {
            HandoverReply::error(
                "ENOHANDOVER",
                "usbvfiod serves a single vfio-user client; two-phase hand-over needs --max-clients > 1",
            )
        },
        |state| match command {
            HandoverCommand::Status => HandoverReply::Ok(state.handover_status().render()),
            HandoverCommand::Ready { conn } => state.handover_ready(conn).map_or_else(
                |e| HandoverReply::error(e.code(), e),
                |status| HandoverReply::Ok(status.render()),
            ),
            HandoverCommand::Commit { conn, epoch } => {
                state.handover_commit(conn, epoch).map_or_else(
                    |e| HandoverReply::error(e.code(), e),
                    |status| HandoverReply::Ok(status.render()),
                )
            }
            HandoverCommand::Abort { conn, reason } => {
                state.handover_abort(conn, &reason).map_or_else(
                    |e| HandoverReply::error(e.code(), e),
                    |status| HandoverReply::Ok(status.render()),
                )
            }
            HandoverCommand::Reclaim { conn, epoch } => {
                state.handover_reclaim(conn, epoch).map_or_else(
                    |e| HandoverReply::error(e.code(), e),
                    |status| HandoverReply::Ok(status.render()),
                )
            }
        },
    );

    reply
        .send_over_socket(socket)
        .context("Failed to send the hand-over reply")
}

fn handle_attach(
    bus: u8,
    dev: u8,
    fd: File,
    socket: &mut UnixStream,
    hotplug_control: &HotplugControl<LocalDevice>,
    async_runtime: &runtime::Handle,
) -> Result<()> {
    let device = nusb::Device::from_fd(fd.into())
        .wait()
        .context("Failed to open nusb device from the supplied file descriptor")?;
    let real_device = NusbRealDevice::try_new(device, async_runtime.clone())?;
    let complete_device = CompleteRealDeviceImpl::new((bus, dev), real_device);
    let response = async_runtime.block_on(hotplug_control.attach(complete_device));
    response
        .send_over_socket(socket)
        .context("Successfully performed hot-plug command, but failed to send the response")?;

    Ok(())
}

fn handle_detach(
    bus: u8,
    dev: u8,
    socket: &mut UnixStream,
    hotplug_control: &HotplugControl<LocalDevice>,
    async_runtime: &runtime::Handle,
) -> Result<()> {
    let response = async_runtime.block_on(hotplug_control.detach((bus, dev)));
    response
        .send_over_socket(socket)
        .context("Successfully performed detach command, but failed to send the response")?;

    Ok(())
}
