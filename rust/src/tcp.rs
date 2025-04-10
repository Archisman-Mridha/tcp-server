use {
  anyhow::anyhow,
  etherparse::{IpNumber, Ipv4Header, Ipv4HeaderSlice, TcpHeader, TcpHeaderSlice},
  std::net::Ipv4Addr,
};

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

    The window sent in each segment indicates the range of sequence numbers the sender of the
    window (the data receiver) is currently prepared to accept. There is an assumption that this is
    related to the currently available data buffer space available for this connection.

    Indicating a large window encourages transmissions. If more data arrives than can be accepted,
    it will be discarded. This will result in excessive retransmissions, adding unnecessarily to
    the load on the network and the TCPs. Indicating a small window may restrict the transmission
    of data to the point of introducing a round trip delay between each new segment transmitted.

    The sending TCP must be prepared to accept from the user and send at least one octet of new
    data even if the send window is zero. The sending TCP must regularly retransmit to the
    receiving TCP even when the window is zero. Two minutes is recommended for the retransmission
    interval when the window is zero. This retransmission is essential to guarantee that when
    either TCP has a zero window the re-opening of the window will be reliably reported to the
    other.

    When the receiving TCP has a zero window and a segment arrives it must still send an
    acknowledgment showing its next expected sequence number and current window (zero).
*/

struct ReceiveSequenceVariables {
  // Represents the sequence number of the next byte that the receiver expects to receive.
  // It ensures the receiver processes the incoming data in the correct order. If an out-of-order
  // segment is received, it will not be acknowledged, and the receiver will wait for the segment
  // matching this value.
  nextByteSequenceNumber: u32, // nxt.

  // Indicates how much buffer space is available for incoming data at the receiver.
  windowSize: u16, // wnd.

  // Tracks the sequence number offset of urgent data in the receive buffer.
  up: bool, // up.

  // The sequence number chosen during the initial handshake as the starting point for the receive
  // side.
  initialReceiveSequenceNumber: u32, // irs.
}

struct SendSequenceVariables {
  // Oldest unacknowledged sequence number.
  oldestUnacknowledgedSequenceNumber: u32, // una.

  // Next sequence number to be sent.
  nextSequenceNumber: u32, // nxt.

  // Send window.
  windowSize: u16, // wnd.

  // Send urgent pointer.
  up: bool,

  // Segment sequence number used for last window update.
  lastWindowUpdateSegmentSequenceNumber: u32, // wl1.

  // Segment acknowledgment number used for last window update.
  lastWindowUpdateAcknowledgementNumber: u32, // wl2.

  // Initial send sequence number.
  initialSendSequenceNumber: u32, // iss.
}

// Represents the TCB.
/*
  The maintenance of a TCP connection requires remembering several variables. We conceive of these
  variables being stored in a connection record called a Transmission Control Block (TCB).
*/
pub struct TCPConnection {
  state: TCPConnectionState,

  receiveSequenceVariables: ReceiveSequenceVariables,
  sendSequenceVariables: SendSequenceVariables,
}

/*
  Initial Sequence Number (ISN) selection and the three way handshake :

  The protocol places no restriction on a particular connection being used over and over again. A
  connection is defined by a pair of sockets. New instances of a connection will be referred to as
  incarnations of the connection.

  The problem that arises from this is : how does the TCP identify duplicate segments from previous
  incarnations of the connection? This problem becomes apparent if the connection is being opened
  and closed in quick succession / if the connection breaks with loss of memory and is then
  re-established.

  To avoid confusion we must prevent segments from one incarnation of a connection from being used,
  while the same sequence numbers may still be present in the network from an earlier incarnation.
  We want to assure this, even if a TCP crashes and loses all knowledge of the sequence numbers it
  has been using.

  When new connections are created, an initial sequence number (ISN) generator is employed which
  selects a new 32 bit ISN.  The generator is bound to a (possibly fictitious) 32 bit clock whose
  low order bit is incremented roughly every 4 microseconds. Thus, the ISN cycles approximately
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

    let initialSendSequenceNumber = 0;
    let sendWindowSize = 1024;

    let mut connection = Self {
      state: TCPConnectionState::SYNReceived,

      receiveSequenceVariables: ReceiveSequenceVariables {
        initialReceiveSequenceNumber: incomingPacketTCPHeader.sequence_number(),
        nextByteSequenceNumber: incomingPacketTCPHeader.sequence_number() + 1,
        windowSize: incomingPacketTCPHeader.window_size(),
        up: false,
      },

      sendSequenceVariables: SendSequenceVariables {
        initialSendSequenceNumber,
        oldestUnacknowledgedSequenceNumber: initialSendSequenceNumber,
        nextSequenceNumber: initialSendSequenceNumber,
        windowSize: sendWindowSize,
        up: false,
        lastWindowUpdateSegmentSequenceNumber: initialSendSequenceNumber,
        lastWindowUpdateAcknowledgementNumber: initialSendSequenceNumber,
      },
    };

    // You can view the TCP header format here :
    // https://datatracker.ietf.org/doc/html/rfc9293#section-3.1
    let mut synAckPacketTCPHeader = TcpHeader::new(
      incomingPacketTCPHeader.destination_port(),
      incomingPacketTCPHeader.source_port(),
      0,
      10,
    );
    synAckPacketTCPHeader.acknowledgment_number = incomingPacketTCPHeader.sequence_number() + 1;
    synAckPacketTCPHeader.ack = true;
    synAckPacketTCPHeader.syn = true;

    // You can view the IPv4 header format here :
    // https://datatracker.ietf.org/doc/html/rfc791#section-3.1.
    let synAckPacketIPv4Header = Ipv4Header::new(
      synAckPacketTCPHeader.to_bytes().len() as u16,
      64,
      IpNumber::TCP,
      incomingPacketIPv4Header.destination(),
      incomingPacketIPv4Header.source(),
    )?;

    let mut arrayBuffer = [0u8; 1024];

    let arrayBufferEmptyPortionLength = {
      let mut sliceBuffer = &mut arrayBuffer[..]; // Convertion from fixed-size array to slice.

      synAckPacketIPv4Header.write(&mut sliceBuffer)?;
      synAckPacketTCPHeader.write(&mut sliceBuffer)?;

      sliceBuffer.len()
    };

    let arrayBufferUsedPortionLength = arrayBuffer.len() - arrayBufferEmptyPortionLength;

    nic.send(&arrayBuffer[..arrayBufferUsedPortionLength])?;

    Ok(connection)
  }
}
