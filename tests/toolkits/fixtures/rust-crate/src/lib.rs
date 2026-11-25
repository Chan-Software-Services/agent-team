//! The rust toolkit's fixture: a closed set of a task's states, each function on it handling every
//! one, and a parse that fails with an error of the crate's own.

mod kind;

pub use kind::{Kind, ParseKindError, is_terminal, label, next, parse};
