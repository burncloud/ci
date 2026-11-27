#![deny(clippy::pedantic)]

#[must_use]
pub const fn marker() -> i32 {
    1
}

#[cfg(test)]
mod database {
    use std::error::Error;
    use std::io::{Read, Write};
    use std::net::{TcpStream, ToSocketAddrs};
    use std::time::Duration;

    #[test]
    fn marker_is_one() {
        assert_eq!(super::marker(), 1);
    }

    #[test]
    fn database_url_reaches_postgres() -> Result<(), Box<dyn Error>> {
        let url = std::env::var("DATABASE_URL").map_err(|_| "DATABASE_URL")?;
        let url = url.strip_prefix("postgres://").ok_or("DATABASE_URL")?;
        let (userinfo, rest) = url.split_once('@').ok_or("DATABASE_URL")?;
        let (hostport, db) = rest.split_once('/').ok_or("DATABASE_URL")?;
        let (host, port_text) = hostport.split_once(':').ok_or("DATABASE_URL")?;
        let user = userinfo.split_once(':').map_or(userinfo, |(u, _)| u);
        let port = port_text.parse::<u16>()?;
        let addr = (host, port)
            .to_socket_addrs()?
            .next()
            .ok_or("DATABASE_URL")?;
        let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(10))?;
        stream.set_read_timeout(Some(Duration::from_secs(10)))?;
        let mut body = 196_608_i32.to_be_bytes().to_vec();
        body.extend_from_slice(b"user\0");
        body.extend_from_slice(user.as_bytes());
        body.extend_from_slice(b"\0database\0");
        body.extend_from_slice(db.as_bytes());
        body.extend_from_slice(b"\0\0");
        let len = i32::try_from(body.len().saturating_add(4))?;
        stream.write_all(&len.to_be_bytes())?;
        stream.write_all(&body)?;
        let mut kind = [0_u8; 1];
        stream.read_exact(&mut kind)?;
        match kind[0] {
            b'R' => Ok(()),
            byte => Err(format!("postgres response {byte}").into()),
        }
    }
}
