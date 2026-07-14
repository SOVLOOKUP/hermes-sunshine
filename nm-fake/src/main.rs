use std::{error::Error, future::pending};
use zbus::{connection, interface};
use zvariant::ObjectPath;

const BUS_NAME: &str = "org.freedesktop.NetworkManager";
const OBJECT_PATH: &str = "/org/freedesktop/NetworkManager";
const ACTIVE_CONNECTION_PATH: &str = "/org/freedesktop/NetworkManager/ActiveConnection/0";
const IP4_CONFIG_PATH: &str = "/org/freedesktop/NetworkManager/IP4Config/0";
const IP6_CONFIG_PATH: &str = "/org/freedesktop/NetworkManager/IP6Config/0";

struct NetworkManager;

#[interface(name = "org.freedesktop.NetworkManager")]
impl NetworkManager {
    fn networking_enabled(&self) -> bool {
        true
    }

    fn wireless_enabled(&self) -> bool {
        false
    }

    fn wireless_hardware_enabled(&self) -> bool {
        false
    }

    fn wwan_enabled(&self) -> bool {
        false
    }

    fn wwan_hardware_enabled(&self) -> bool {
        false
    }

    fn active_connections(&self) -> Vec<ObjectPath<'_>> {
        vec![ObjectPath::try_from(ACTIVE_CONNECTION_PATH).unwrap()]
    }

    fn primary_connection(&self) -> ObjectPath<'_> {
        ObjectPath::try_from(ACTIVE_CONNECTION_PATH).unwrap()
    }

    fn state(&self) -> u32 {
        70
    }

    fn connectivity(&self) -> u32 {
        4
    }
}

struct ActiveConnection;

#[interface(name = "org.freedesktop.NetworkManager.Connection.Active")]
impl ActiveConnection {
    fn id(&self) -> &str {
        "Docker Network"
    }

    fn uuid(&self) -> &str {
        "docker-network-uuid"
    }

    fn connection(&self) -> ObjectPath<'_> {
        ObjectPath::try_from("/org/freedesktop/NetworkManager/Settings/0").unwrap()
    }

    fn devices(&self) -> Vec<ObjectPath<'_>> {
        Vec::new()
    }

    fn state(&self) -> u32 {
        2
    }

    fn default(&self) -> bool {
        true
    }

    fn ipv4_config(&self) -> ObjectPath<'_> {
        ObjectPath::try_from("/org/freedesktop/NetworkManager/IP4Config/0").unwrap()
    }

    fn ipv6_config(&self) -> ObjectPath<'_> {
        ObjectPath::try_from("/org/freedesktop/NetworkManager/IP6Config/0").unwrap()
    }
}

struct IP4Config;

#[interface(name = "org.freedesktop.NetworkManager.IP4Config")]
impl IP4Config {
    fn addresses(&self) -> Vec<(u32, u32, ObjectPath<'_>)> {
        Vec::new()
    }

    fn gateways(&self) -> Vec<(i32, u32, ObjectPath<'_>)> {
        Vec::new()
    }

    fn nameservers(&self) -> Vec<u32> {
        Vec::new()
    }

    fn domains(&self) -> Vec<&str> {
        Vec::new()
    }

    fn wins_servers(&self) -> Vec<u32> {
        Vec::new()
    }

    fn routes(&self) -> Vec<(u32, u32, u32, i32, ObjectPath<'_>)> {
        Vec::new()
    }

    fn gateway(&self) -> u32 {
        0
    }

    fn method(&self) -> u32 {
        2
    }

    fn is_gateway(&self) -> bool {
        false
    }

    fn dns_servers(&self) -> Vec<u32> {
        Vec::new()
    }

    fn dns_search(&self) -> Vec<&str> {
        Vec::new()
    }
}

struct IP6Config;

#[interface(name = "org.freedesktop.NetworkManager.IP6Config")]
impl IP6Config {
    fn addresses(&self) -> Vec<(Vec<u8>, u32, i32, ObjectPath<'_>)> {
        Vec::new()
    }

    fn gateways(&self) -> Vec<(i32, u32, ObjectPath<'_>)> {
        Vec::new()
    }

    fn nameservers(&self) -> Vec<Vec<u8>> {
        Vec::new()
    }

    fn domains(&self) -> Vec<&str> {
        Vec::new()
    }

    fn routes(&self) -> Vec<(Vec<u8>, u32, Vec<u8>, i32, ObjectPath<'_>)> {
        Vec::new()
    }

    fn gateway(&self) -> Vec<u8> {
        Vec::new()
    }

    fn method(&self) -> u32 {
        2
    }

    fn is_gateway(&self) -> bool {
        false
    }

    fn dns_servers(&self) -> Vec<Vec<u8>> {
        Vec::new()
    }

    fn dns_search(&self) -> Vec<&str> {
        Vec::new()
    }

    fn dhcp_iaid(&self) -> u32 {
        0
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let _conn = connection::Builder::system()?
        .name(BUS_NAME)?
        .serve_at(OBJECT_PATH, NetworkManager)?
        .serve_at(ACTIVE_CONNECTION_PATH, ActiveConnection)?
        .serve_at(IP4_CONFIG_PATH, IP4Config)?
        .serve_at(IP6_CONFIG_PATH, IP6Config)?
        .build()
        .await?;

    println!("fake NetworkManager started on D-Bus");
    pending::<()>().await;

    Ok(())
}
