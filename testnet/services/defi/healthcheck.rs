use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

fn healthy() -> Result<bool, Box<dyn std::error::Error>> {
    let bind: SocketAddr = std::env::var("DEFI_NODE_BIND")
        .unwrap_or_else(|_| "0.0.0.0:7100".into())
        .parse()?;
    // Probe this container only, regardless of the interface on which it binds.
    let address = SocketAddr::from(([127, 0, 0, 1], bind.port()));
    let timeout = Duration::from_secs(2);
    let mut stream = TcpStream::connect_timeout(&address, timeout)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    stream.write_all(b"GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")?;
    let mut status = Vec::new();
    BufReader::new(stream)
        .take(256)
        .read_until(b'\n', &mut status)?;
    let ok = status.starts_with(b"HTTP/1.1 200 ") || status.starts_with(b"HTTP/1.0 200 ");
    Ok(ok && status.ends_with(b"\r\n"))
}

fn main() {
    if !matches!(healthy(), Ok(true)) {
        eprintln!("DeFi simulator health probe failed");
        std::process::exit(1);
    }
}
