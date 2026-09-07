//! Agent driver: one credentialed process that routes every model request across providers,
//! tracks quota windows, and records dispatch lineage. Workers never hold provider credentials.
pub mod adapter;
pub mod api;
pub mod bootstrap;
pub mod client;
pub mod cursor_agent;
pub mod dispatch;
pub mod log;
pub mod openrouter;
pub mod quota;
pub mod registry;
