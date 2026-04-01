//! Wrenflow hub crate — entry point for Rust logic.
//! Communicates with Flutter/Dart via rinf signals.

mod actors;
mod logging;
pub mod signals;

use actors::create_actors;
use rinf::{dart_shutdown, write_interface};
use tokio::spawn;

write_interface!();

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    // Initialize logging + panic hook (visible in `flutter run`)
    logging::init_logging();
    logging::install_panic_hook();

    log::info!("Wrenflow Rust hub starting");

    // Spawn the actor system
    spawn(create_actors());

    // Keep running until Dart shuts down
    dart_shutdown().await;
}
