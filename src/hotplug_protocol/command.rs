use std::fs::File;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;

use vmm_sys_util::errno::Error;
use vmm_sys_util::sock_ctrl_msg::ScmSocket;

use super::handover::{read_line, HandoverCommand, HandoverProtocolError};

const COMMAND_ATTACH: u8 = 0;
const COMMAND_DETACH: u8 = 1;
const COMMAND_LIST: u8 = 2;

#[derive(Debug)]
pub enum Command {
    Attach {
        bus: u8,
        device: u8,
        fd: File,
    },
    Detach {
        bus: u8,
        device: u8,
    },
    List,
    /// Two-phase ownership control; see [`super::handover`].
    Handover(HandoverCommand),
}

impl Command {
    pub fn send_over_socket(self, socket: &UnixStream) -> Result<(), CommandSendError> {
        let id = self.variant_to_id();
        let (buf, fd) = match &self {
            Self::Attach { bus, device, fd } => ([id, *bus, *device], Some(fd.as_raw_fd())),
            Self::Detach { bus, device } => ([id, *bus, *device], None),
            Self::List => ([id, 0, 0], None),
            Self::Handover(command) => {
                // The hand-over commands are line-oriented and written in one
                // `sendmsg`; the receiver knows to read a line because of the id.
                command.send_over_socket(socket)?;
                return Ok(());
            }
        };

        let transmitted = fd.map_or_else(
            || socket.send_with_fds(&[&buf[..]], &[]),
            |fd| socket.send_with_fd(&buf[..], fd),
        )?;

        // TODO implement a transmission loop to be safe (we should not run
        // into problems with how little data we send, though).
        if transmitted == buf.len() {
            Ok(())
        } else {
            Err(CommandSendError::NotSentEnough(buf.len(), transmitted))
        }
    }

    pub fn receive_from_socket(socket: &UnixStream) -> Result<Self, CommandReceiveError> {
        // Read the command id on its own. The three legacy commands are
        // fixed-size messages whose ancillary data rides on the first byte, so
        // reading a single byte still delivers their file descriptor; the
        // hand-over commands continue with a text line.
        let mut id = [0u8; 1];
        let (bytes_read, file) = socket.recv_with_fd(&mut id[..])?;
        if bytes_read != id.len() {
            return Err(CommandReceiveError::NotEnoughData(id.len(), bytes_read));
        }

        if id[0] == HandoverCommand::COMMAND_ID {
            if file.is_some() {
                return Err(CommandReceiveError::UnexpectedFd);
            }
            let line = read_line(socket).map_err(CommandReceiveError::Handover)?;
            let command = HandoverCommand::parse(&line).map_err(CommandReceiveError::Handover)?;
            return Ok(Self::Handover(command));
        }

        let mut rest = [0u8; 2];
        let mut filled = 0;
        while filled < rest.len() {
            let (n, extra) = socket.recv_with_fd(&mut rest[filled..])?;
            if n == 0 {
                return Err(CommandReceiveError::NotEnoughData(rest.len(), filled));
            }
            if extra.is_some() {
                return Err(CommandReceiveError::UnexpectedFd);
            }
            filled += n;
        }

        match (id[0], file) {
            (COMMAND_ATTACH, Some(file)) => Ok(Self::Attach {
                bus: rest[0],
                device: rest[1],
                fd: file,
            }),
            (COMMAND_ATTACH, None) => Err(CommandReceiveError::MissingFd),
            (COMMAND_DETACH, None) => Ok(Self::Detach {
                bus: rest[0],
                device: rest[1],
            }),
            (COMMAND_LIST, None) => Ok(Self::List {}),
            (command, None) => Err(CommandReceiveError::UnknownCommand(command)),
            (_, Some(_)) => Err(CommandReceiveError::UnexpectedFd),
        }
    }

    const fn variant_to_id(&self) -> u8 {
        match self {
            Self::Attach {
                bus: _,
                device: _,
                fd: _,
            } => COMMAND_ATTACH,
            Self::Detach { bus: _, device: _ } => COMMAND_DETACH,
            Self::List => COMMAND_LIST,
            Self::Handover(_) => HandoverCommand::COMMAND_ID,
        }
    }
}

#[derive(thiserror::Error, Debug)]
pub enum CommandReceiveError {
    #[error("did not receive enough data over the socket. Expected {0}, received {1}")]
    NotEnoughData(usize, usize),
    #[error("expected to receive a file descriptor, but there was none")]
    MissingFd,
    #[error("did not expect to receive a file descriptor, but there was one")]
    UnexpectedFd,
    #[error("Unknown command")]
    UnknownCommand(u8),
    #[error("Malformed hand-over command: {0}")]
    Handover(#[from] HandoverProtocolError),
    #[error("Encountered errno during socket IO")]
    ErrnoError(#[from] Error),
}

#[derive(thiserror::Error, Debug)]
pub enum CommandSendError {
    #[error("did not receive enough data over the socket. Expected to send {0}, sent {1}")]
    NotSentEnough(usize, usize),
    #[error("Encountered errno during socket IO")]
    ErrnoError(#[from] Error),
}
