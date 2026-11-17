// The prod-mongo toolkit's settings, the one place they are written: the server's name, the
// 1Password reference of the read user's connection string, the one database every tool works on,
// the backups folder, written from ~/, and the repository whose migrations a rehearsal runs, under
// its owner today and the one before 2026-11-14, which a checkout's origin may still name
// (bin/lib/repo-moves.json). start-server.mjs, which alone reads 1Password, and the
// container scripts, which read no credential, all take them from here.
export const settings = {
  name: "prod-mongo",
  reference: "op://agent-team/conventioner-prod-read/uri",
  database: "conventioner",
  root: "~/conventioner-backups",
  repositories: ["Chan-Software-Services/Conventioner", "chanjdaniel/Conventioner"],
};
