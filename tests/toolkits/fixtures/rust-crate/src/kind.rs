use std::error::Error;
use std::fmt;

/// The states a task can be in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Opened,
    Closed,
    Parked,
}

/// The state's name as the ledger writes it.
pub fn label(kind: Kind) -> &'static str {
    match kind {
        Kind::Opened => "opened",
        Kind::Closed => "closed",
        Kind::Parked => "parked",
    }
}

/// Whether nothing follows the state.
pub fn is_terminal(kind: Kind) -> bool {
    match kind {
        Kind::Opened => false,
        Kind::Closed => true,
        Kind::Parked => false,
    }
}

/// The state that follows, if any.
pub fn next(kind: Kind) -> Option<Kind> {
    match kind {
        Kind::Opened => Some(Kind::Parked),
        Kind::Closed => None,
        Kind::Parked => Some(Kind::Opened),
    }
}

/// Why a name is no state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseKindError {
    Empty,
    Unknown(String),
}

impl fmt::Display for ParseKindError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseKindError::Empty => write!(f, "no state named"),
            ParseKindError::Unknown(name) => write!(f, "no state is named {name:?}"),
        }
    }
}

impl Error for ParseKindError {}

/// The state a name gives, as `label` writes it.
pub fn parse(name: &str) -> Result<Kind, ParseKindError> {
    match name {
        "" => Err(ParseKindError::Empty),
        "opened" => Ok(Kind::Opened),
        "closed" => Ok(Kind::Closed),
        "parked" => Ok(Kind::Parked),
        other => Err(ParseKindError::Unknown(other.to_owned())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Kind; 3] = [Kind::Opened, Kind::Closed, Kind::Parked];

    #[test]
    fn parse_reads_every_label() {
        for kind in ALL {
            assert_eq!(parse(label(kind)).unwrap(), kind);
        }
    }

    #[test]
    fn parse_refuses_an_empty_or_unknown_name() {
        assert_eq!(parse(""), Err(ParseKindError::Empty));
        assert_eq!(
            parse("merged"),
            Err(ParseKindError::Unknown("merged".to_owned()))
        );
    }

    #[test]
    fn a_terminal_state_has_no_next() {
        for kind in ALL {
            assert_eq!(is_terminal(kind), next(kind).is_none());
        }
    }
}
