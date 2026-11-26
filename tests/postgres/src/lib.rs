#![forbid(unsafe_code)]
#![deny(warnings)]
#![deny(clippy::pedantic)]

#[cfg(test)]
mod database {
    use std::io::{ErrorKind, Read, Write};
    use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
    use std::time::{Duration, Instant};

    const PROTOCOL: i32 = 196_608;
    const MAX_PAYLOAD: usize = 65_536;

    struct Endpoint {
        host: String,
        port: u16,
        user: String,
        database: String,
    }

    fn text(message: &str) -> String {
        message.to_owned()
    }

    fn bad_url() -> String {
        text("DATABASE_URL")
    }

    fn show(err: &std::io::Error) -> String {
        err.to_string()
    }

    fn parse_port(value: &str) -> Result<u16, String> {
        value.parse::<u16>().map_err(|_| bad_url())
    }

    fn parse_host_port(authority: &str) -> Result<(&str, u16), String> {
        if let Some(rest) = authority.strip_prefix('[') {
            let (host, after) = rest.split_once(']').ok_or_else(bad_url)?;
            if host.is_empty() {
                return Err(bad_url());
            }
            let port = match after.strip_prefix(':') {
                Some(value) => parse_port(value)?,
                None if after.is_empty() => 5432,
                None => return Err(bad_url()),
            };
            return Ok((host, port));
        }
        if let Some((host, value)) = authority.rsplit_once(':') {
            if host.is_empty() {
                return Err(bad_url());
            }
            return Ok((host, parse_port(value)?));
        }
        if authority.is_empty() {
            return Err(bad_url());
        }
        Ok((authority, 5432))
    }

    fn parse_database_url(url: &str) -> Result<Endpoint, String> {
        let rest = url
            .strip_prefix("postgres://")
            .or_else(|| url.strip_prefix("postgresql://"))
            .ok_or_else(bad_url)?;
        let (userinfo, hostpart) = rest.rsplit_once('@').ok_or_else(bad_url)?;
        let user = match userinfo.split_once(':') {
            Some((name, _password)) => name,
            None => userinfo,
        };
        if user.is_empty() {
            return Err(bad_url());
        }
        let (authority, path) = hostpart.split_once('/').ok_or_else(bad_url)?;
        let database = match path.split(['?', '#']).next() {
            Some(name) if !name.is_empty() => name,
            _ => return Err(bad_url()),
        };
        let (host, port) = parse_host_port(authority)?;
        Ok(Endpoint {
            host: host.to_owned(),
            port,
            user: user.to_owned(),
            database: database.to_owned(),
        })
    }

    fn push_cstr(buf: &mut Vec<u8>, bytes: &[u8]) {
        buf.extend_from_slice(bytes);
        buf.push(0);
    }

    fn startup_message(user: &str, database: &str) -> Result<Vec<u8>, String> {
        if user.is_empty() || database.is_empty() || user.contains('\0') || database.contains('\0')
        {
            return Err(text("startup"));
        }
        let mut body = Vec::new();
        body.extend_from_slice(&PROTOCOL.to_be_bytes());
        push_cstr(&mut body, b"user");
        push_cstr(&mut body, user.as_bytes());
        push_cstr(&mut body, b"database");
        push_cstr(&mut body, database.as_bytes());
        body.push(0);
        let total = body.len().checked_add(4).ok_or_else(|| text("startup"))?;
        let len = i32::try_from(total).map_err(|_| text("startup"))?;
        let mut message = Vec::with_capacity(total);
        message.extend_from_slice(&len.to_be_bytes());
        message.extend_from_slice(&body);
        Ok(message)
    }

    fn socket_addr(host: &str, port: u16) -> Result<SocketAddr, String> {
        let mut addrs = (host, port).to_socket_addrs().map_err(|err| show(&err))?;
        addrs.next().ok_or_else(bad_url)
    }

    fn configure(stream: &TcpStream) -> Result<(), String> {
        stream.set_nodelay(true).map_err(|err| show(&err))?;
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .map_err(|err| show(&err))?;
        stream
            .set_write_timeout(Some(Duration::from_secs(10)))
            .map_err(|err| show(&err))?;
        Ok(())
    }

    fn dial(host: &str, port: u16) -> Result<TcpStream, String> {
        let addr = socket_addr(host, port)?;
        let stream =
            TcpStream::connect_timeout(&addr, Duration::from_secs(10)).map_err(|err| show(&err))?;
        configure(&stream)?;
        Ok(stream)
    }

    fn read_i32(bytes: &[u8]) -> Result<i32, String> {
        let chunk = bytes.get(..4).ok_or_else(|| text("postgres"))?;
        let array: [u8; 4] = chunk.try_into().map_err(|_| text("postgres"))?;
        Ok(i32::from_be_bytes(array))
    }

    fn read_message(stream: &mut TcpStream) -> Result<(u8, Vec<u8>), String> {
        let mut header = [0_u8; 5];
        stream.read_exact(&mut header).map_err(|err| show(&err))?;
        let (kind, rest) = header.split_first().ok_or_else(|| text("postgres"))?;
        let len = read_i32(rest)?;
        if len < 4 {
            return Err(text("postgres"));
        }
        let payload_len = usize::try_from(len - 4).map_err(|_| text("postgres"))?;
        if payload_len > MAX_PAYLOAD {
            return Err(text("postgres"));
        }
        let mut payload = vec![0_u8; payload_len];
        stream.read_exact(&mut payload).map_err(|err| show(&err))?;
        Ok((*kind, payload))
    }

    fn known_auth(code: i32) -> bool {
        matches!(code, 0 | 3 | 5 | 10)
    }

    fn handshake(stream: &mut TcpStream, user: &str, database: &str) -> Result<(), String> {
        let message = startup_message(user, database)?;
        stream.write_all(&message).map_err(|err| show(&err))?;
        stream.flush().map_err(|err| show(&err))?;
        let (kind, payload) = read_message(stream)?;
        if kind != b'R' {
            return Err(format!("postgres response {kind}"));
        }
        let code = read_i32(&payload)?;
        if !known_auth(code) {
            return Err(format!("postgres auth {code}"));
        }
        Ok(())
    }

    fn reach(endpoint: &Endpoint) -> Result<(), String> {
        let mut stream = dial(&endpoint.host, endpoint.port)?;
        handshake(&mut stream, &endpoint.user, &endpoint.database)
    }

    fn retryable(err: &std::io::Error) -> bool {
        matches!(err.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted)
    }

    fn accept_once(listener: &TcpListener) -> Result<TcpStream, String> {
        listener.set_nonblocking(true).map_err(|err| show(&err))?;
        let start = Instant::now();
        loop {
            match listener.accept() {
                Ok((stream, _addr)) => {
                    stream.set_nonblocking(false).map_err(|err| show(&err))?;
                    configure(&stream)?;
                    return Ok(stream);
                }
                Err(err) if retryable(&err) => {
                    if start.elapsed() > Duration::from_secs(2) {
                        return Err(text("accept"));
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(err) => return Err(show(&err)),
            }
        }
    }

    fn auth_message(kind: u8, code: i32) -> Vec<u8> {
        let mut payload = code.to_be_bytes().to_vec();
        let len = if code == 10 {
            payload.extend_from_slice(b"SCRAM-SHA-256\0\0");
            23_i32
        } else {
            8_i32
        };
        let mut message = Vec::with_capacity(payload.len().saturating_add(5));
        message.push(kind);
        message.extend_from_slice(&len.to_be_bytes());
        message.extend_from_slice(&payload);
        message
    }

    fn serve(listener: &TcpListener, kind: u8, code: i32) -> Result<(), String> {
        let mut stream = accept_once(listener)?;
        let mut header = [0_u8; 4];
        stream.read_exact(&mut header).map_err(|err| show(&err))?;
        stream
            .write_all(&auth_message(kind, code))
            .map_err(|err| show(&err))?;
        stream.flush().map_err(|err| show(&err))
    }

    fn with_server(
        kind: u8,
        code: i32,
        check: fn(u16) -> Result<(), String>,
    ) -> Result<(), String> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(|err| show(&err))?;
        let port = listener.local_addr().map_err(|err| show(&err))?.port();
        let handle = std::thread::spawn(move || serve(&listener, kind, code));
        let result = check(port);
        match handle.join() {
            Ok(server) => result.and(server),
            Err(_payload) => Err(text("server thread")),
        }
    }

    fn local_handshake(port: u16) -> Result<Result<(), String>, String> {
        let mut stream = dial("127.0.0.1", port)?;
        Ok(handshake(&mut stream, "postgres", "postgres"))
    }

    fn expect_sasl(port: u16) -> Result<(), String> {
        local_handshake(port)?
    }

    fn expect_response_rejected(port: u16) -> Result<(), String> {
        match local_handshake(port)? {
            Ok(()) => Err(text("accepted a non-postgres response")),
            Err(err) if err.starts_with("postgres response") => Ok(()),
            Err(err) => Err(err),
        }
    }

    fn expect_auth_rejected(port: u16) -> Result<(), String> {
        match local_handshake(port)? {
            Ok(()) => Err(text("accepted unknown auth")),
            Err(err) if err.starts_with("postgres auth") => Ok(()),
            Err(err) => Err(err),
        }
    }

    #[test]
    fn parses_database_url() -> Result<(), String> {
        let endpoint = parse_database_url("postgres://postgres:postgres@127.0.0.1:5432/postgres")?;
        if endpoint.host != "127.0.0.1"
            || endpoint.port != 5432
            || endpoint.user != "postgres"
            || endpoint.database != "postgres"
        {
            return Err(text("postgres url"));
        }
        let alias = parse_database_url("postgresql://app@localhost/app")?;
        if alias.host != "localhost"
            || alias.port != 5432
            || alias.user != "app"
            || alias.database != "app"
        {
            return Err(text("alias url"));
        }
        let v6 = parse_database_url("postgres://postgres@[::1]:5433/postgres?sslmode=disable")?;
        if v6.host != "::1" || v6.port != 5433 || v6.database != "postgres" {
            return Err(text("ipv6 url"));
        }
        Ok(())
    }

    #[test]
    fn rejects_database_url() -> Result<(), String> {
        for sample in [
            "",
            "http://postgres:postgres@127.0.0.1:5432/postgres",
            "postgres://127.0.0.1:5432/postgres",
            "postgres://postgres:postgres@/postgres",
            "postgres://postgres:postgres@127.0.0.1:5432/",
            "postgres://:postgres@127.0.0.1:5432/postgres",
            "postgres://postgres:postgres@127.0.0.1:5432",
        ] {
            if parse_database_url(sample).is_ok() {
                return Err(text("accepted DATABASE_URL"));
            }
        }
        Ok(())
    }

    #[test]
    fn startup_message_is_protocol_3() -> Result<(), String> {
        let message = startup_message("postgres", "postgres")?;
        let expected: &[u8] = &[
            0, 0, 0, 41, 0, 3, 0, 0, b'u', b's', b'e', b'r', 0, b'p', b'o', b's', b't', b'g', b'r',
            b'e', b's', 0, b'd', b'a', b't', b'a', b'b', b'a', b's', b'e', 0, b'p', b'o', b's',
            b't', b'g', b'r', b'e', b's', 0, 0,
        ];
        if message.as_slice() != expected {
            return Err(text("startup"));
        }
        Ok(())
    }

    #[test]
    fn reads_sasl_authentication() -> Result<(), String> {
        with_server(b'R', 10, expect_sasl)
    }

    #[test]
    fn rejects_non_postgres_banner() -> Result<(), String> {
        with_server(b'X', 0, expect_response_rejected)
    }

    #[test]
    fn rejects_unknown_auth() -> Result<(), String> {
        with_server(b'R', 99, expect_auth_rejected)
    }

    #[test]
    fn database_url_reaches_postgres() -> Result<(), String> {
        let url = std::env::var("DATABASE_URL").map_err(|_| bad_url())?;
        let endpoint = parse_database_url(&url)?;
        reach(&endpoint)
    }
}
