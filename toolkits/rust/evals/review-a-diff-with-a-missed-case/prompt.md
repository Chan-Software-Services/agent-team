---
description: A reviewer asked to review a diff that adds a variant fires the skill, and names the wildcard arm that hides it.
tags: [rust]
model: claude-opus-5-5
max_turns: 15
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

Review this diff to the Rust crate in this directory and list your findings, each with its fix:

```diff
--- a/src/kind.rs
+++ b/src/kind.rs
@@ -7,6 +7,7 @@ pub enum Kind {
     Opened,
     Closed,
     Parked,
+    Reopened,
 }
 
 /// The state's name as the ledger writes it.
@@ -15,6 +16,7 @@ pub fn label(kind: Kind) -> &'static str {
         Kind::Opened => "opened",
         Kind::Closed => "closed",
         Kind::Parked => "parked",
+        Kind::Reopened => "reopened",
     }
 }
 
@@ -24,6 +26,7 @@ pub fn is_terminal(kind: Kind) -> bool {
         Kind::Opened => false,
         Kind::Closed => true,
         Kind::Parked => false,
+        _ => false,
     }
 }
 
@@ -33,6 +36,7 @@ pub fn next(kind: Kind) -> Option<Kind> {
         Kind::Opened => Some(Kind::Parked),
         Kind::Closed => None,
         Kind::Parked => Some(Kind::Opened),
+        Kind::Reopened => Some(Kind::Opened),
     }
 }
 
@@ -61,6 +65,7 @@ pub fn parse(name: &str) -> Result<Kind, ParseKindError> {
         "opened" => Ok(Kind::Opened),
         "closed" => Ok(Kind::Closed),
         "parked" => Ok(Kind::Parked),
+        "reopened" => Ok(Kind::Reopened),
         other => Err(ParseKindError::Unknown(other.to_owned())),
     }
 }
@@ -69,7 +74,7 @@ pub fn parse(name: &str) -> Result<Kind, ParseKindError> {
 mod tests {
     use super::*;
 
-    const ALL: [Kind; 3] = [Kind::Opened, Kind::Closed, Kind::Parked];
+    const ALL: [Kind; 4] = [Kind::Opened, Kind::Closed, Kind::Parked, Kind::Reopened];
 
     #[test]
     fn parse_reads_every_label() {
```
