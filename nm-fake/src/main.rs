use std::{error::Error, future::pending};
use zbus::{connection, interface};
use zvariant::ObjectPath;

const BUS_NAME: &str = "org.freedesktop.NetworkManager";
const OBJECT_PATH: &str = "/org/freedesktop/NetworkManager";

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
        Vec::new()
    }

    fn primary_connection(&self) -> ObjectPath<'_> {
        ObjectPath::try_from("/org/freedesktop/NetworkManager/ActiveConnection/0").unwrap()
    }

    fn state(&self) -> u32 {
        70
    }

    fn connectivity(&self) -> u32 {
        4
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let _conn = connection::Builder::system()?
        .name(BUS_NAME)?
        .serve_at(OBJECT_PATH, NetworkManager)?
        .build()
        .await?;

    println!("fake NetworkManager started on D-Bus");
    pending::<()>().await;

    Ok(())
}
