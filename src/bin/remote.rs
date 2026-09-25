#![deny(
    clippy::all,
    clippy::cargo,
    clippy::nursery,
    clippy::must_use_candidate
)]
// now allow a few rules which are denied by the above's statement
#![allow(clippy::multiple_crate_versions)]
#![deny(missing_debug_implementations)]
#![deny(rustdoc::all)]

//! Command-line tool to attach/detach/list USB devices to/from usbvfiod at runtime.

use std::{
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
};

use anyhow::{anyhow, Context, Result};
use clap::{ArgAction, Parser};
use nusb::MaybeFuture;
use usbvfiod::hotplug_protocol::{
    command::Command,
    device_paths::resolve_path,
    handover::{HandoverCommand, HandoverReply, HandoverSnapshot},
    response::Response,
};

fn main() -> Result<()> {
    let args = Cli::parse();

    if let Some(path) = args.attach {
        attach(path.as_path(), args.socket.as_path())?;
    } else if let Some(vec) = args.detach {
        // Safety: clap ensures that vec.len() == 2.
        let bus = vec[0];
        let dev = vec[1];
        detach(bus, dev, args.socket.as_path())?;
    } else if args.list {
        list_attached(args.socket.as_path())?;
    } else if args.handover_status {
        report(handover(args.socket.as_path(), &HandoverCommand::Status)?)?;
    } else if let Some(role) = args.handover_ready {
        let conn = resolve_conn(args.socket.as_path(), &role)?;
        report(handover(
            args.socket.as_path(),
            &HandoverCommand::Ready { conn },
        )?)?;
    } else if let Some(role) = args.handover_commit {
        let snapshot = status(args.socket.as_path())?;
        let conn = resolve(&snapshot, &role)?;
        let reply = handover(
            args.socket.as_path(),
            &HandoverCommand::Commit {
                conn,
                epoch: snapshot.epoch,
            },
        )?;
        report(reply)?;
    } else if let Some(vec) = args.handover_abort {
        // Safety: clap ensures that vec.len() is 1 or 2.
        let role = &vec[0];
        let reason = vec.get(1).cloned().unwrap_or_default();
        let conn = resolve_conn(args.socket.as_path(), role)?;
        report(handover(
            args.socket.as_path(),
            &HandoverCommand::Abort { conn, reason },
        )?)?;
    } else if let Some(role) = args.handover_reclaim {
        let snapshot = status(args.socket.as_path())?;
        let conn = resolve(&snapshot, &role)?;
        let reply = handover(
            args.socket.as_path(),
            &HandoverCommand::Reclaim {
                conn,
                epoch: snapshot.epoch,
            },
        )?;
        report(reply)?;
    }

    Ok(())
}

/// Send one hand-over command and read its answer.
fn handover(socket_path: &Path, command: &HandoverCommand) -> Result<HandoverReply> {
    let socket = UnixStream::connect(socket_path).context("Failed to open socket")?;
    command
        .send_over_socket(&socket)
        .context("Failed to send the hand-over command over the socket")?;
    HandoverReply::receive_from_socket(&socket).context("Failed to receive the hand-over reply")
}

/// Ask the server for the current ownership state.
fn status(socket_path: &Path) -> Result<HandoverSnapshot> {
    match handover(socket_path, &HandoverCommand::Status)? {
        HandoverReply::Ok(body) => Ok(HandoverSnapshot::parse(&body)),
        HandoverReply::Err { code, detail } => Err(anyhow!(
            "the server refused a status query: {code}: {detail}"
        )),
    }
}

/// Resolve `owner`/`prev`/`candidate`/`<id>` to a connection id.
///
/// A numeric id needs no extra round trip, so it is answered locally.
fn resolve_conn(socket_path: &Path, role: &str) -> Result<u64> {
    if let Ok(id) = role.parse::<u64>() {
        return Ok(id);
    }
    resolve(&status(socket_path)?, role)
}

fn resolve(snapshot: &HandoverSnapshot, role: &str) -> Result<u64> {
    snapshot
        .resolve(role)
        .ok_or_else(|| anyhow!("no connection is currently {role:?} (see --handover-status)"))
}

/// Print a successful answer's payload; turn a refusal into an error exit.
fn report(reply: HandoverReply) -> Result<()> {
    match reply {
        HandoverReply::Ok(body) => {
            println!("{body}");
            Ok(())
        }
        HandoverReply::Err { code, detail } => Err(anyhow!("{code}: {detail}")),
    }
}

fn attach(device_path: &Path, socket_path: &Path) -> Result<()> {
    let (bus, dev, device_path) = resolve_path(device_path)
        .with_context(|| format!("Failed to resolve device path {device_path:?}"))?;

    println!("Requesting attachment of device {bus:03}:{dev:03}");

    let open_file = |err_msg: &str| {
        std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&device_path)
            .with_context(|| err_msg.to_string())
    };

    let file = open_file("Failed to open USB device file")?;
    let device = nusb::Device::from_fd(file.into())
        .wait()
        .context("Failed to open nusb device")?;
    device.reset().wait().context("Failed to reset device")?;

    // After the reset, the device instance is no longer usable and we need
    // to reopen.
    let file = open_file("Failed to open USB device file after device reset")?;

    // write to socket for hot-attach fds
    let command = Command::Attach {
        bus,
        device: dev,
        fd: file,
    };
    let mut socket = UnixStream::connect(socket_path).context("Failed to open socket")?;
    command
        .send_over_socket(&socket)
        .context("Failed to send attach command over the socket")?;

    let response = Response::receive_from_socket(&mut socket)
        .context("Failed to receive response over the socket")?;
    println!("{response:?}");

    Ok(())
}

fn detach(bus: u8, dev: u8, socket_path: &Path) -> Result<()> {
    println!("Requesting detach of device {bus:03}:{dev:03}");

    let command = Command::Detach { bus, device: dev };
    let mut socket = UnixStream::connect(socket_path).context("Failed to open socket")?;
    command
        .send_over_socket(&socket)
        .context("Failed to send detach command over the socket")?;

    let response = Response::receive_from_socket(&mut socket)
        .context("Failed to receive response over the socket")?;
    println!("{response:?}");

    Ok(())
}

fn list_attached(socket_path: &Path) -> Result<()> {
    let mut socket = UnixStream::connect(socket_path).context("Failed to open socket")?;
    Command::List
        .send_over_socket(&socket)
        .context("Failed to send list command over socket")?;

    let response = Response::receive_from_socket(&mut socket)
        .context("Failed to receive response over the socket")?;

    if response != Response::ListFollowing {
        return Err(anyhow!(
            "Expected the response {:?} but got {:?}",
            Response::ListFollowing,
            response
        ));
    }

    let device_list = response.receive_devices_list(&mut socket)?;
    match device_list.len() {
        0 => println!("No attached devices"),
        1 => {
            println!("One attached device:");
            println!("{:03}:{:03}", device_list[0].0, device_list[0].1);
        }
        count => {
            println!("{count} attached devices:");
            for (bus, dev) in device_list {
                println!("{bus:03}:{dev:03}");
            }
        }
    }

    Ok(())
}

#[derive(Parser, Debug)]
#[command(
    name = env!("CARGO_PKG_NAME"),
    version = env!("CARGO_PKG_VERSION"),
    author = env!("CARGO_PKG_AUTHORS"),
    about = env!("CARGO_PKG_DESCRIPTION"),
    long_about = None,
    group = clap::ArgGroup::new("action").required(true).multiple(false).args([
        "attach",
        "detach",
        "list",
        "handover_status",
        "handover_ready",
        "handover_commit",
        "handover_abort",
        "handover_reclaim",
    ])
)]
struct Cli {
    /// Path to the hot-attach socket that the usbvfiod instances exposes.
    #[arg(long, value_name = "PATH")]
    socket: PathBuf,

    /// Attach the USB device to usbvfiod. The path must point to a device in: /dev/bus/usb.
    /// This option is mutually exclusive with --detach and --list.
    #[arg(
        long,
        value_name = "PATH",
        conflicts_with = "detach",
        conflicts_with = "list"
    )]
    attach: Option<PathBuf>,

    /// Detach the USB device from usbvfiod. Specify the device with the bus number
    /// and the device number.
    ///
    /// This option is mutually exclusive with --attach and --list.
    #[arg(long, num_args = 2, conflicts_with = "attach", conflicts_with = "list")]
    detach: Option<Vec<u8>>,

    /// List the currently attached USB devices.
    ///
    /// This option is mutually exclusive with --attach and --detach.
    #[arg(long, action = ArgAction::SetTrue, conflicts_with = "attach", conflicts_with = "detach")]
    list: bool,

    /// Print the two-phase ownership state (owner, previous owner, staged
    /// candidate, epoch, readiness).
    #[arg(long)]
    handover_status: bool,

    /// Declare the staged hand-over candidate ready, which is what allows a
    /// commit. Arguments other than a number are resolved through a status
    /// query, so `candidate` is usually what you want.
    #[arg(long, value_name = "CONN")]
    handover_ready: Option<String>,

    /// Commit the staged hand-over: from here on the candidate owns the interrupt
    /// line and the previous owner may reclaim within the lease.
    #[arg(long, value_name = "CONN")]
    handover_commit: Option<String>,

    /// Drop the staged candidate. The incumbent is untouched, which is the right
    /// answer to "the destination has a problem".
    #[arg(long, value_name = "CONN", num_args = 1..=2)]
    handover_abort: Option<Vec<String>>,

    /// Give the device back to the previous owner after a committed hand-over
    /// went wrong. Only the previous owner may reclaim, and only within the lease.
    #[arg(long, value_name = "CONN")]
    handover_reclaim: Option<String>,
}
