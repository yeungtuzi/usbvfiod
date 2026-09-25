//! Control-path protocol for the two-phase device hand-over.
//!
//! The three legacy commands (`attach`/`detach`/`list`) are fixed-size binary
//! messages. The hand-over commands carry a connection id, an epoch and a
//! free-form reason, none of which fit into the two spare bytes, so they use a
//! line-oriented text encoding on the same socket instead. The first byte is the
//! same kind of command id as before ([`HandoverCommand::COMMAND_ID`]), followed
//! by one UTF-8 line terminated by `\n`:
//!
//! ```text
//! status
//! watch <timeout-ms>
//! ready <conn>
//! commit <conn> <epoch>
//! abort <conn> [reason...]
//! reclaim <conn> <epoch>
//! ```
//!
//! Answers are also one line, either
//!
//! ```text
//! ok owner=0 prev=- candidate=1 epoch=1 ready=false lease_ms=5000 live=[0, 1]
//! ```
//!
//! or
//!
//! ```text
//! err code=EPREFLIGHT_NOT_READY detail=the driver has not declared the destination ready
//! ```
//!
//! The reason a text protocol was chosen over extending the fixed-size one is
//! diagnosability: every hand-over decision is a policy decision, and a policy
//! decision that cannot be read back is hard to debug. The `remote` tool
//! (`src/bin/remote.rs`) is the supported client; the encoding is deliberately
//! simple enough to drive by hand with `socat` during an incident.

use std::{
    fmt,
    io::{self, BufRead, BufReader, Read, Write},
    os::unix::net::UnixStream,
};

use vmm_sys_util::sock_ctrl_msg::ScmSocket;

use super::command::CommandSendError;

/// Longest request line accepted, including the terminating newline.
///
/// A control command is a few dozen bytes; the bound exists so that a client
/// which never sends a newline cannot make the server grow a buffer without
/// limit.
pub const MAX_LINE: usize = 1024;

/// A hand-over command as it travels over the control socket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HandoverCommand {
    /// Report the ownership state of every connection.
    Status,
    /// Block until a candidate is staged or the ownership moves, then report the
    /// state. A candidate exists for a few milliseconds in practice, which is
    /// shorter than a control round trip, so a controller that polls cannot
    /// observe one reliably; waiting on the server side can.
    Watch { timeout_ms: u64 },
    /// The driver declares that the destination VM is ready for the device.
    Ready { conn: u64 },
    /// Atomically hand the device to `conn`, which must be the staged candidate.
    Commit { conn: u64, epoch: u64 },
    /// Drop the staged candidate; the incumbent keeps the device.
    Abort { conn: u64, reason: String },
    /// The previous owner takes the device back within its lease.
    Reclaim { conn: u64, epoch: u64 },
}

impl HandoverCommand {
    /// Command id that introduces a hand-over request on the control socket.
    pub const COMMAND_ID: u8 = 3;

    /// Encode as the single wire line, without the trailing newline.
    #[must_use]
    pub fn encode(&self) -> String {
        match self {
            Self::Status => "status".to_owned(),
            Self::Watch { timeout_ms } => format!("watch {timeout_ms}"),
            Self::Ready { conn } => format!("ready {conn}"),
            Self::Commit { conn, epoch } => format!("commit {conn} {epoch}"),
            Self::Abort { conn, reason } => {
                if reason.is_empty() {
                    format!("abort {conn}")
                } else {
                    // A reason is free text; a newline would split the message.
                    format!("abort {conn} {}", reason.replace(['\n', '\r'], " "))
                }
            }
            Self::Reclaim { conn, epoch } => format!("reclaim {conn} {epoch}"),
        }
    }

    /// Parse the wire line, without the trailing newline.
    pub fn parse(line: &str) -> Result<Self, HandoverProtocolError> {
        let mut words = line.split_whitespace();
        let verb = words
            .next()
            .ok_or_else(|| HandoverProtocolError::new("empty hand-over command"))?;
        let conn =
            |words: &mut std::str::SplitWhitespace<'_>| -> Result<u64, HandoverProtocolError> {
                words
                    .next()
                    .ok_or_else(|| HandoverProtocolError::new("missing connection id"))?
                    .parse()
                    .map_err(|_| HandoverProtocolError::new("connection id is not a number"))
            };
        let epoch =
            |words: &mut std::str::SplitWhitespace<'_>| -> Result<u64, HandoverProtocolError> {
                words
                    .next()
                    .ok_or_else(|| HandoverProtocolError::new("missing epoch"))?
                    .parse()
                    .map_err(|_| HandoverProtocolError::new("epoch is not a number"))
            };
        let timeout =
            |words: &mut std::str::SplitWhitespace<'_>| -> Result<u64, HandoverProtocolError> {
                words
                    .next()
                    .ok_or_else(|| HandoverProtocolError::new("missing timeout in milliseconds"))?
                    .parse()
                    .map_err(|_| HandoverProtocolError::new("timeout is not a number"))
            };
        let command = match verb {
            "status" => Self::Status,
            "watch" => Self::Watch {
                timeout_ms: timeout(&mut words)?,
            },
            "ready" => Self::Ready {
                conn: conn(&mut words)?,
            },
            "commit" => Self::Commit {
                conn: conn(&mut words)?,
                epoch: epoch(&mut words)?,
            },
            "abort" => {
                // A reason is free text and may contain spaces, so it consumes
                // whatever is left of the line; there is nothing to check for
                // trailing arguments afterwards.
                let conn = conn(&mut words)?;
                let reason = words.collect::<Vec<_>>().join(" ");
                return Ok(Self::Abort { conn, reason });
            }
            "reclaim" => Self::Reclaim {
                conn: conn(&mut words)?,
                epoch: epoch(&mut words)?,
            },
            other => {
                return Err(HandoverProtocolError::new(format!(
                    "unknown hand-over command {other:?}"
                )))
            }
        };
        if let Some(unexpected) = words.next() {
            return Err(HandoverProtocolError::new(format!(
                "unexpected trailing argument {unexpected:?}"
            )));
        }
        Ok(command)
    }

    /// Write the command id and the encoded line to `socket`.
    pub fn send_over_socket(&self, socket: &UnixStream) -> Result<(), CommandSendError> {
        let line = format!("{}\n", self.encode());
        let mut message = Vec::with_capacity(line.len() + 1);
        message.push(Self::COMMAND_ID);
        message.extend_from_slice(line.as_bytes());
        socket.send_with_fds(&[&message[..]], &[])?;
        Ok(())
    }
}

/// The answer to a [`HandoverCommand`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HandoverReply {
    /// The command succeeded; the payload is the rendered ownership state.
    Ok(String),
    /// The command was refused; `code` is stable and machine-checkable.
    Err { code: String, detail: String },
}

impl HandoverReply {
    /// Build an error reply from a stable code and a human-readable detail.
    #[must_use]
    pub fn error(code: &str, detail: impl fmt::Display) -> Self {
        Self::Err {
            code: code.to_owned(),
            detail: detail.to_string().replace(['\n', '\r'], " "),
        }
    }

    /// The stable error code, if this is an error reply.
    #[must_use]
    pub fn code(&self) -> Option<&str> {
        match self {
            Self::Ok(_) => None,
            Self::Err { code, .. } => Some(code),
        }
    }

    /// Encode as the single wire line, without the trailing newline.
    #[must_use]
    pub fn encode(&self) -> String {
        match self {
            Self::Ok(body) => format!("ok {body}"),
            Self::Err { code, detail } => format!("err code={code} detail={detail}"),
        }
    }

    /// Parse the wire line, without the trailing newline.
    pub fn parse(line: &str) -> Result<Self, HandoverProtocolError> {
        if let Some(body) = line.strip_prefix("ok") {
            return Ok(Self::Ok(body.trim_start().to_owned()));
        }
        let Some(rest) = line.strip_prefix("err") else {
            return Err(HandoverProtocolError::new(format!(
                "unexpected hand-over reply {line:?}"
            )));
        };
        let mut code = String::new();
        let mut detail = String::new();
        for field in rest.split_whitespace() {
            if let Some(value) = field.strip_prefix("code=") {
                code = value.to_owned();
            } else if let Some(value) = field.strip_prefix("detail=") {
                detail = value.to_owned();
            } else if !detail.is_empty() {
                detail.push(' ');
                detail.push_str(field);
            }
        }
        if code.is_empty() {
            return Err(HandoverProtocolError::new("error reply without a code"));
        }
        Ok(Self::Err { code, detail })
    }

    /// Write the reply line to `socket`.
    pub fn send_over_socket(&self, socket: &mut UnixStream) -> io::Result<()> {
        socket.write_all(format!("{}\n", self.encode()).as_bytes())
    }

    /// Read a reply line from `socket`.
    ///
    /// The socket is wrapped in a fresh [`BufReader`] per call, which is exactly
    /// what a one-shot control connection needs: the client sends one command and
    /// reads one answer, then closes.
    pub fn receive_from_socket(socket: &UnixStream) -> Result<Self, HandoverProtocolError> {
        let line = read_line(socket)?;
        Self::parse(&line)
    }
}

/// Read one newline-terminated line, bounded by [`MAX_LINE`].
#[must_use = "the read line is the whole point of the call"]
pub fn read_line(socket: &UnixStream) -> Result<String, HandoverProtocolError> {
    let mut reader = BufReader::new(socket.try_clone()?);
    let mut line = String::new();
    let mut limited = (&mut reader).take((MAX_LINE + 1) as u64);
    limited
        .read_line(&mut line)
        .map_err(|e| HandoverProtocolError::new(format!("failed to read the reply: {e}")))?;
    if line.is_empty() {
        return Err(HandoverProtocolError::new(
            "the control connection closed before an answer arrived",
        ));
    }
    if !line.ends_with('\n') {
        return Err(HandoverProtocolError::new(
            "the control connection sent an unterminated line",
        ));
    }
    Ok(line.trim_end_matches(['\n', '\r']).to_owned())
}

/// A control-protocol failure: a malformed message or an I/O error.
#[derive(Debug)]
pub struct HandoverProtocolError {
    detail: String,
}

impl HandoverProtocolError {
    /// Build an error with the given detail.
    pub fn new(detail: impl fmt::Display) -> Self {
        Self {
            detail: detail.to_string(),
        }
    }
}

impl fmt::Display for HandoverProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.detail)
    }
}

impl std::error::Error for HandoverProtocolError {}

impl From<io::Error> for HandoverProtocolError {
    fn from(value: io::Error) -> Self {
        Self::new(format!("control socket I/O failed: {value}"))
    }
}

/// The ownership fields of a successful reply, parsed for the `remote` tool.
///
/// This is the client-side mirror of `SharedBackendState::handover_status()`;
/// both sides spell the keys identically on purpose.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct HandoverSnapshot {
    /// Connection currently owning the device.
    pub owner: Option<u64>,
    /// Connection that owned the device before the last commit.
    pub prev: Option<u64>,
    /// Connection staged as the next owner.
    pub candidate: Option<u64>,
    /// Hand-over generation; changes on every ownership change.
    pub epoch: u64,
    /// Whether the candidate has declared itself ready.
    pub ready: bool,
    /// Reclaim window after a commit, in milliseconds.
    pub lease_ms: u64,
    /// Whether the destination's registration reply is held for a controller.
    pub binding: bool,
    /// Whether a control client has been seen (binding degrades without one).
    pub controller: bool,
    /// Whether the DMA-coverage precondition is deferred to after the commit.
    pub deferred_a3: bool,
}

impl HandoverSnapshot {
    /// Parse the `key=value` body of an `ok` reply.
    #[must_use]
    pub fn parse(body: &str) -> Self {
        fn number(field: &str, key: &str) -> Option<u64> {
            field.strip_prefix(key)?.parse().ok()
        }
        let mut snapshot = Self::default();
        for field in body.split_whitespace() {
            if let Some(v) = number(field, "owner=") {
                snapshot.owner = Some(v);
            } else if let Some(v) = number(field, "prev=") {
                snapshot.prev = Some(v);
            } else if let Some(v) = number(field, "candidate=") {
                snapshot.candidate = Some(v);
            } else if let Some(v) = number(field, "epoch=") {
                snapshot.epoch = v;
            } else if let Some(v) = number(field, "lease_ms=") {
                snapshot.lease_ms = v;
            } else if let Some(v) = field.strip_prefix("ready=") {
                snapshot.ready = v == "true";
            } else if let Some(v) = field.strip_prefix("binding=") {
                snapshot.binding = v == "true";
            } else if let Some(v) = field.strip_prefix("controller=") {
                snapshot.controller = v == "true";
            } else if let Some(v) = field.strip_prefix("deferred_a3=") {
                snapshot.deferred_a3 = v == "true";
            }
        }
        snapshot
    }

    /// Resolve one of the role keywords a human or a harness may type instead of
    /// a numeric connection id.
    #[must_use]
    pub fn resolve(&self, role: &str) -> Option<u64> {
        match role {
            "owner" => self.owner,
            "prev" => self.prev,
            "candidate" => self.candidate,
            _ => role.parse().ok(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{HandoverCommand, HandoverReply, HandoverSnapshot};

    #[test]
    fn commands_round_trip() {
        for command in [
            HandoverCommand::Status,
            HandoverCommand::Watch { timeout_ms: 5000 },
            HandoverCommand::Ready { conn: 7 },
            HandoverCommand::Commit { conn: 7, epoch: 3 },
            HandoverCommand::Abort {
                conn: 0,
                reason: "destination guest did not enumerate the disk".to_owned(),
            },
            HandoverCommand::Abort {
                conn: 0,
                reason: String::new(),
            },
            HandoverCommand::Reclaim { conn: 1, epoch: 4 },
        ] {
            let encoded = command.encode();
            let decoded = HandoverCommand::parse(&encoded).expect("round trip");
            assert_eq!(decoded, command, "encoded as {encoded:?}");
        }
    }

    #[test]
    fn malformed_commands_are_rejected() {
        for malformed in [
            "",
            "handover",
            "ready",
            "ready x",
            "commit 1",
            "commit 1 x",
            "status extra",
            "watch",
            "watch x",
            "reclaim 1 2 3",
        ] {
            HandoverCommand::parse(malformed)
                .expect_err(&format!("{malformed:?} must be rejected"));
        }
    }

    #[test]
    fn replies_round_trip() {
        let ok = HandoverReply::Ok(
            "owner=0 prev=- candidate=1 epoch=1 ready=false lease_ms=5000 live=[0, 1]".to_owned(),
        );
        assert_eq!(
            HandoverReply::parse(&ok.encode()).expect("round trip"),
            ok,
            "{}",
            ok.encode()
        );
        let err = HandoverReply::error("EPREFLIGHT_NOT_READY", "not ready yet");
        assert_eq!(
            HandoverReply::parse(&err.encode()).expect("round trip"),
            err
        );
        assert_eq!(err.code(), Some("EPREFLIGHT_NOT_READY"));
        HandoverReply::parse("ok").expect("a bare ok carries an empty payload");
        HandoverReply::parse("err detail=nothing")
            .expect_err("an error reply without a code is malformed");
        HandoverReply::parse("maybe").expect_err("an unknown reply must be rejected");
    }

    #[test]
    fn error_details_survive_a_multi_word_message() {
        let reply = HandoverReply::error("EBACKEND", "no candidate is staged");
        let encoded = reply.encode();
        assert_eq!(
            HandoverReply::parse(&encoded).expect("round trip"),
            reply,
            "{encoded}"
        );
    }

    #[test]
    fn a_reason_with_a_newline_cannot_split_the_message() {
        let command = HandoverCommand::Abort {
            conn: 2,
            reason: "two\nlines".to_owned(),
        };
        assert_eq!(command.encode(), "abort 2 two lines");
        // The newline is replaced rather than escaped, so the decoded reason is
        // the sanitised one: one wire line, always.
        assert_eq!(
            HandoverCommand::parse(&command.encode()).expect("round trip"),
            HandoverCommand::Abort {
                conn: 2,
                reason: "two lines".to_owned(),
            }
        );
    }

    #[test]
    fn snapshot_parses_a_rendered_status() {
        let snapshot = HandoverSnapshot::parse(
            "owner=0 prev=- candidate=1 epoch=1 ready=true lease_ms=5000 binding=true controller=false",
        );
        assert_eq!(snapshot.owner, Some(0));
        assert_eq!(snapshot.prev, None);
        assert_eq!(snapshot.candidate, Some(1));
        assert_eq!(snapshot.epoch, 1);
        assert!(snapshot.ready);
        assert_eq!(snapshot.lease_ms, 5000);
        assert!(snapshot.binding);
        assert!(!snapshot.controller);
        assert_eq!(snapshot.resolve("owner"), Some(0));
        assert_eq!(snapshot.resolve("prev"), None);
        assert_eq!(snapshot.resolve("candidate"), Some(1));
        assert_eq!(snapshot.resolve("9"), Some(9));
        assert_eq!(snapshot.resolve("nonsense"), None);
    }
}
