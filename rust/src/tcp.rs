use anyhow::anyhow;
use etherparse::{IpNumber, Ipv4Header, Ipv4HeaderSlice, TcpHeader, TcpHeaderSlice};
use std::net::Ipv4Addr;

#[derive(PartialEq, Eq, Hash)]
pub struct Location {
  pub address: Ipv4Addr,
  pub port: u16,
}

#[derive(PartialEq, Eq, Hash)]
pub struct ConnectionQuad {
  pub source: Location,
  pub destiation: Location,
}

#[derive(Default)]
pub enum TCPConnectionState {
  #[default]
  Closed,

  Listen,

  SYNReceived,

  Established,
}

/*
  (1) Sequence Numbers :

    Every octet of data sent over a TCP connection has a sequence number. Since every octet is
    sequenced, each of them can be acknowledged. The acknowledgment mechanism employed is
    cumulative so that an acknowledgment of sequence number X indicates that all octets up to but
    not including X have been received. This mechanism allows for straight-forward duplicate
    detection in the presence of retransmission. Numbering of octets within a segment is that the
    first data octet immediately following the header is the lowest numbered, and the following
    octets are numbered consecutively.

    It is essential to remember that the actual sequence number space is finite, though very large.
    This space ranges from 0 to (2**32 - 1).

  (2) Window :
*/

struct ReceiveSequenceVariables {
  // Represents the sequence number of the next byte that the receiver expects to receive.
  // It ensures the receiver processes the incoming data in the correct order. If an out-of-order
  // segment is received, it will not be acknowledged, and the receiver will wait for the segment
  // matching this value.
  nxt: usize,

  // Indicates how much buffer space is available for incoming data at the receiver.
  wnd: usize,

  // Tracks the sequence number offset of urgent data in the receive buffer.
  up: usize,

  // The sequence number chosen during the initial handshake as the starting point for the receive
  // side.
  irs: usize,
}

struct SendSequenceVariables {
  una: usize,
  nxt: usize,
  wnd: usize,
  up: usize,
  wl1: usize,
  wl2: usize,
  iss: usize,
}

// Represents the TCB.
/*
  The maintenance of a TCP connection requires the remembering of several variables. We conceive
  of these variables being stored in a connection record called a Transmission Control Block (TCB).
*/
pub struct TCPConnection {
  state: TCPConnectionState,

  receiveSequenceVariables: ReceiveSequenceVariables,
  sendSequenceVariables: SendSequenceVariables,
}

/*
  Initial Sequence Number (ISN) selection and the three way handshake :

  The protocol places no restriction on a particular connection being used over and over again. A
  connection is defined by a pair of sockets.

  New instances of a connection will be referred to as incarnations of the connection. The problem
  that arises from this is : how does the TCP identify duplicate segments from previous
  incarnations of the connection? This problem becomes apparent if the connection is being opened
  and closed in quick succession / if the connection breaks with loss of memory and is then
  re-established.

  To avoid confusion we must prevent segments from one incarnation of a connection from being used
  while the same sequence numbers may still be present in the network from an earlier incarnation.
  We want to assure this, even if a TCP crashes and loses all knowledge of the sequence numbers it
  has been using.

  When new connections are created, an initial sequence number (ISN) generator is employed which
  selects a new 32 bit ISN.  The generator is bound to a (possibly fictitious) 32 bit clock whose
  low order bit is incremented roughly every 4 microseconds.  Thus, the ISN cycles approximately
  every 4.55 hours. Since we assume that segments will stay in the network no more than the
  Maximum Segment Lifetime (MSL) and that the MSL is less than 4.55 hours we can reasonably assume
  that ISN's will be unique.

  For each connection there is a send sequence number and a receive sequence number. The initial
  send sequence number (ISS) is chosen by the data sending TCP, and the initial receive sequence
  number (IRS) is learned during the connection establishing procedure.

  For a connection to be established or initialized, the two TCPs must synchronize on each other's
  initial sequence numbers. This is done in an exchange of connection establishing segments
  carrying a control bit called SYN (for synchronize) and the initial sequence numbers. As a
  shorthand, segments carrying the SYN bit are also called SYNs. Hence, the solution requires a
  suitable mechanism for picking an initial sequence number and a slightly involved handshake to
  exchange the ISN's.

  The synchronization requires each side to send it's own initial sequence number and to receive a
  confirmation of it in acknowledgment from the other side. Each side must also receive the other
  side's initial sequence number and send a confirming acknowledgment.

    (1) A --> B  SYN my sequence number is X
    (2) A <-- B  ACK your sequence number is X + (3) A <-- B  SYN my sequence number is Y
    (4) A --> B  ACK your sequence number is Y

  Because steps 2 and 3 can be combined in a single message this is called the three way (or three
  message) handshake.

  A three way handshake is necessary because sequence numbers are not tied to a global clock in the
  network, and TCPs may have different mechanisms for picking the ISN's. The receiver of the first
  SYN has no way of knowing whether the segment was an old delayed one or not, unless it remembers
  the last sequence number used on the connection (which is not always possible), and so it must
  ask the sender to verify this SYN.
*/
impl TCPConnection {
  pub fn accept<'connection>(
    incomingPacketIPv4Header: Ipv4HeaderSlice<'connection>,
    incomingPacketTCPHeader: TcpHeaderSlice<'connection>,
    data: &'connection [u8],
    nic: &mut tun::Device,
  ) -> anyhow::Result<Self> {
    if !incomingPacketTCPHeader.syn() {
      return Err(anyhow!("Three way handshake not done"));
    }

    // We've received a SYN packet from the client.
    // Start establishing a connection, by sending back a SYN ACK packet.

    let mut connection = Self {
      state: TCPConnectionState::SYNReceived,

      receiveSequenceVariables: ReceiveSequenceVariables {},

      sendSequenceVariables: SendSequenceVariables {
        una: (),
        nxt: (),
        ack: (),
        seq: (),
        len: (),
      },
    };

    let mut buffer = [0u8; 1024];
    let mut buffer = &mut buffer[..]; // Convertion from fixed-size array to slice.

    let mut synAckPacketTCPHeader = TcpHeader::new(
      incomingPacketTCPHeader.destination_port(),
      incomingPacketTCPHeader.source_port(),
      0,
      10,
    );
    synAckPacketTCPHeader.acknowledgment_number = incomingPacketTCPHeader.sequence_number() + 1;
    synAckPacketTCPHeader.ack = true;
    synAckPacketTCPHeader.syn = true;

    let synAckPacketIPv4Header = Ipv4Header::new(
      synAckPacketTCPHeader.to_bytes().len() as u16,
      64,
      IpNumber::TCP,
      incomingPacketIPv4Header.destination(),
      incomingPacketIPv4Header.source(),
    )?;

    synAckPacketIPv4Header.write(&mut buffer)?;
    synAckPacketTCPHeader.write(&mut buffer)?;

    nic.send(&buffer[..buffer.len()])?;

    Ok(connection)
  }
}
