# Implementing a TCP server from scratch

## Knowledge nuggets

- The UT8 or ASCII encoding of 4,294,967,295 takes 10 bytes - 1 byte per digit. The binary encoding takes 4 bytes; quite the space saving! Conversely, the UTF8 or ASCII encoding of "63" uses just 2 bytes, versus the 4 byte if we're using a **4-byte fixed length**.

  > There are variable-length binary encoding scheme, such as the `varint` used by Google's **Protocol Buffer**.

- Some protocols use **both delimiters and some type of prefix**. HTTP, for example, uses delimiters for its headers, but the body's length is typically defined by the text-encoded Content-Length header. Redis also stands out as having a mix of both delimiters (for ease of human-readability) and text-encoded length prefix.

## REFERENCEs

- [TUN/TAP](https://en.wikipedia.org/wiki/TUN/TAP)
- [TRANSMISSION CONTROL PROTOCOL](https://www.ietf.org/rfc/rfc793.txt)
- [INTERNET PROTOCOL](https://datatracker.ietf.org/doc/html/rfc791)
- [Datagrams](https://en.wikipedia.org/wiki/Datagram)
- [SYN flood attack](https://www.cloudflare.com/en-in/learning/ddos/syn-flood-ddos-attack/)

- [TCP Server in Zig - Part 1 - Single Threaded](https://www.openmymind.net/TCP-Server-In-Zig-Part-1-Single-Threaded/)
