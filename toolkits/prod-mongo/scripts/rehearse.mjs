// The migration rehearsal, as the prod-mongo server runs it and as Daniel or the coordinator may,
// from a checkout of Conventioner and always through the machine's heavy-run lock:
//
//   cd <a Conventioner checkout> && ~/agent-team/bin/team-heavy run --kind rehearsal -- node ~/agent-team/toolkits/prod-mongo/scripts/rehearse.mjs <stamp> <sha> <script>... [--text]
//
// Builds Conventioner's back-end image at the commit <sha> (its full sha), restores the dump
// ~/conventioner-backups/<stamp>/ into a throwaway local MongoDB on a Docker network with no route
// out, runs each migration script (a file's name under back-end/migrations/) against it in order,
// with --dry-run first when its text holds that flag, stopping at a dry run that wrote or a run
// that exited non-zero, and records in the dump's rehearsals/ folder each run's output and what it
// changed, by counts and ids. Removes the MongoDB, the network and the image. Prints one JSON object
// on stdout, or with --text the tool's answer, and each step as it starts on stderr; exits 0 when
// every script ran, nothing stopped the rehearsal and nothing was left in Docker, 1 otherwise, and
// 128 plus the signal's number when stopped by one. Reads no credential and takes no connection string. See servers/prod-mongo/rehearse.mjs.
import { rehearse } from "../../../servers/prod-mongo/rehearse.mjs";
import { settings } from "./settings.mjs";

await rehearse({ argv: process.argv.slice(2), database: settings.database, root: settings.root, repositories: settings.repositories });
