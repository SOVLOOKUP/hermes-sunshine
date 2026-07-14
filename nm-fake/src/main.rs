use std::{error::Error, future::pending};
use zbus::{connection, interface};
use zvariant::ObjectPath;

const BUS_NAME: &str = "org.freedesktop.NetworkManager";
const OBJECT_PATH: &str = "/org/freedesktop/NetworkManager";
const ACTIVE_CONNECTION_PATH: &str = "/org/freedesktop/NetworkManager/ActiveConnection/0";
const IP4_CONFIG_PATH: &str = "/org/freedesktop/NetworkManager/IP4Config/0";
const IP6_CONFIG_PATH: &str = "/org/freedesktop/NetworkManager/IP6Config/0";
const WIRED_DEVICE_PATH: &str = "/org/freedesktop/NetworkManager/Devices/0";

struct NetworkManager;

#[interface(name = "org.freedesktop.NetworkManager")]
impl NetworkManager {
    #[zbus(property)]
    fn networking_enabled(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn wireless_enabled(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn wireless_hardware_enabled(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn wwan_enabled(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn wwan_hardware_enabled(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn active_connections(&self) -> Vec<ObjectPath<'_>> {
        vec![ObjectPath::try_from(ACTIVE_CONNECTION_PATH).unwrap()]
    }

    #[zbus(property)]
    fn primary_connection(&self) -> ObjectPath<'_> {
        ObjectPath::try_from(ACTIVE_CONNECTION_PATH).unwrap()
    }

    #[zbus(property)]
    fn state(&self) -> u32 {
        70
    }

    #[zbus(property)]
    fn connectivity(&self) -> u32 {
        4
    }

    #[zbus(property)]
    fn devices(&self) -> Vec<ObjectPath<'_>> {
        vec![ObjectPath::try_from(WIRED_DEVICE_PATH).unwrap()]
    }

    #[zbus(property)]
    fn primary_connection_type(&self) -> &str {
        "802-3-ethernet"
    }
}

struct ActiveConnection;

#[interface(name = "org.freedesktop.NetworkManager.Connection.Active")]
impl ActiveConnection {
    #[zbus(property)]
    fn id(&self) -> &str {
        "Docker Network"
    }

    #[zbus(property)]
    fn uuid(&self) -> &str {
        "docker-network-uuid"
    }

    #[zbus(property)]
    fn type_(&self) -> &str {
        "802-3-ethernet"
    }

    #[zbus(property)]
    fn connection(&self) -> ObjectPath<'_> {
        ObjectPath::try_from("/org/freedesktop/NetworkManager/Settings/0").unwrap()
    }

    #[zbus(property)]
    fn devices(&self) -> Vec<ObjectPath<'_>> {
        vec![ObjectPath::try_from(WIRED_DEVICE_PATH).unwrap()]
    }

    #[zbus(property)]
    fn state(&self) -> u32 {
        2
    }

    #[zbus(property)]
    fn default(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn ipv4_config(&self) -> ObjectPath<'_> {
        ObjectPath::try_from("/org/freedesktop/NetworkManager/IP4Config/0").unwrap()
    }

    #[zbus(property)]
    fn ipv6_config(&self) -> ObjectPath<'_> {
        ObjectPath::try_from("/org/freedesktop/NetworkManager/IP6Config/0").unwrap()
    }
}

struct IP4Config;

#[interface(name = "org.freedesktop.NetworkManager.IP4Config")]
impl IP4Config {
    #[zbus(property)]
    fn addresses(&self) -> Vec<(u32, u32, ObjectPath<'_>)> {
        Vec::new()
    }

    #[zbus(property)]
    fn nameservers(&self) -> Vec<u32> {
        Vec::new()
    }

    #[zbus(property)]
    fn domains(&self) -> Vec<&str> {
        Vec::new()
    }

    #[zbus(property)]
    fn gateway(&self) -> &str {
        "172.17.0.1"
    }
}

struct IP6Config;

#[interface(name = "org.freedesktop.NetworkManager.IP6Config")]
impl IP6Config {
    #[zbus(property)]
    fn addresses(&self) -> Vec<(Vec<u8>, u32, i32, ObjectPath<'_>)> {
        Vec::new()
    }

    #[zbus(property)]
    fn nameservers(&self) -> Vec<Vec<u8>> {
        Vec::new()
    }

    #[zbus(property)]
    fn domains(&self) -> Vec<&str> {
        Vec::new()
    }

    #[zbus(property)]
    fn gateway(&self) -> &str {
        ""
    }
}

struct WiredDevice;

#[interface(name = "org.freedesktop.NetworkManager.Device")]
impl WiredDevice {
    #[zbus(property)]
    fn ip4_config(&self) -> ObjectPath<'_> {
        ObjectPath::try_from(IP4_CONFIG_PATH).unwrap()
    }

    #[zbus(property)]
    fn ip6_config(&self) -> ObjectPath<'_> {
        ObjectPath::try_from(IP6_CONFIG_PATH).unwrap()
    }

    #[zbus(property)]
    fn managed(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn name(&self) -> &str {
        "eth0"
    }

    #[zbus(property)]
    fn state(&self) -> u32 {
        100
    }

    #[zbus(property)]
    fn type_(&self) -> u32 {
        1
    }

    #[zbus(property)]
    fn active_connection(&self) -> ObjectPath<'_> {
        ObjectPath::try_from(ACTIVE_CONNECTION_PATH).unwrap()
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
        .serve_at(WIRED_DEVICE_PATH, WiredDevice)?
        .build()
        .await?;

    println!("fake NetworkManager started on D-Bus");
    pending::<()>().await;

    Ok(())
}
