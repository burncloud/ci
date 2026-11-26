#[cfg(test)]
mod database {
    use postgres::NoTls;

    #[test]
    fn database_url_connects() {
        let url = std::env::var("DATABASE_URL").expect("DATABASE_URL");
        assert!(!url.is_empty(), "DATABASE_URL");
        let mut client = postgres::Client::connect(&url, NoTls).expect("connect");
        let row = client.query_one("SELECT 1", &[]).expect("select");
        let value: i32 = row.get(0);
        assert_eq!(value, 1);
    }
}
