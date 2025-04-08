#![allow(non_snake_case)]

use etherparse::IpNumber;
use std::collections::hash_map::{Entry, HashMap};
use tcp::{ConnectionQuad, Location, TCPConnection};

mod tcp;

fn main() -> anyhow::Result<()> {
  /*
    TUN and TAP are kernel virtual network devices.

    TUN, namely network TUNnel (acts like a virtual Network Interface Card), simulates a network
    layer device and operates in layer 3 carrying IP packets. TUN is used with routing.

    TAP, namely network TAP (acts like a virtual Ethernet cable), simulates a link layer device and
    operates in layer 2 carrying Ethernet frames. TAP can be used to create a user space network
    bridge.

    Packets sent by an operating system via a TUN/TAP device, are delivered to a user space program
    which attaches itself to the device.
    A user space program may also pass packets into a TUN/TAP device. In this case the TUN/TAP
    device delivers (or injects) these packets to the operating-system network stack thus emulating
    their reception from an external source.

    REFERENCE : https://en.wikipedia.org/wiki/TUN/TAP
  */

  let mut vNICConfig = tun::Configuration::default();
  vNICConfig
    .tun_name("utun4")
    .address("10.0.0.1")
    /*
      Range of IPs that are considered "directly reachable" via this interface. This tells your
      OS : if you're sending a packet to anything in 10.0.0.0/24, route it through utun4.
    */
    .netmask((255, 255, 255, 0))
    .destination("10.0.0.255")
    .up();

  let mut vNIC = tun::create(&vNICConfig)?;
  println!("Created virtual Network Interface Card (vNIC)");

  let mut connections = HashMap::<ConnectionQuad, TCPConnection>::default();

  let mut buffer = [0u8; 1024]; // size = 1 KB.

  loop {
    /*
      TCP segments are sent as internet datagrams.

      A datagram is s self-contained, independent entity of data carrying sufficient information to
      be routed from the source to the destination computer without reliance on earlier exchanges
      between this source and destination computer and the transporting network.

      Each datagram has two components :

        (1) Header : contains all the information sufficient for routing from the originating
            equipment to the destination without relying on prior exchanges between the equipment
            and the network.

        (2) Payload : the data to be transported.
    */
    let bytesRead = vNIC.recv(&mut buffer)?;

    let ipv4PacketHeader = match etherparse::Ipv4HeaderSlice::from_slice(&buffer[..bytesRead]) {
      Ok(ipv4PacketHeader) => ipv4PacketHeader,
      _ => {
        eprintln!("Ignoring packet, since it doesn't follow the IPv4 protocol");
        continue;
      }
    };
    let ipv4PacketHeaderLen = ipv4PacketHeader.slice().len();

    if ipv4PacketHeader.protocol() != IpNumber::TCP {
      println!("Ignoring non TCP IPv4 packet");
      continue;
    }

    let ipv4PacketPayload = &buffer[ipv4PacketHeaderLen..bytesRead];

    let tcpPacketHeader = match etherparse::TcpHeaderSlice::from_slice(ipv4PacketPayload) {
      Ok(tcpPacketHeader) => tcpPacketHeader,
      _ => {
        eprintln!("Ignoring packet, since it doesn't have a valid TCP header section");
        continue;
      }
    };
    let tcpPacketHeaderLen = tcpPacketHeader.slice().len();

    let tcpPacketPayload = &buffer[(ipv4PacketHeaderLen + tcpPacketHeaderLen)..bytesRead];

    let connectionQuad = ConnectionQuad {
      source: Location {
        address: ipv4PacketHeader.source_addr(),
        port: tcpPacketHeader.source_port(),
      },
      destiation: Location {
        address: ipv4PacketHeader.destination_addr(),
        port: tcpPacketHeader.destination_port(),
      },
    };
    match connections.entry(connectionQuad) {
      // No existing connection.
      // So accept and save the new connection.
      Entry::Vacant(entry) => {
        let newConnection = match TCPConnection::accept(
          ipv4PacketHeader,
          tcpPacketHeader,
          tcpPacketPayload,
          &mut vNIC,
        ) {
          Ok(newConnection) => newConnection,

          Err(error) => {
            println!("Failed accepting new connection : {}", error);
            continue;
          }
        };

        entry.insert(newConnection);
      }

      // Connection exists.
      // Process the packet.
      Entry::Occupied(mut existingConnection) => unimplemented!(),
    }
  }
}
