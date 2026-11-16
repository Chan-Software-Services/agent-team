// prod-mongo's reads of the project's repository, in the server's working directory, the session's
// worktree: whose checkout it is, and the commit a ref names as origin has it. The rehearsal runs
// the migrations of that commit, and the integrity check reads its invariants file.
//
//   await commitOf({ cwd, ref, repositories, progress })
//                            { sha, stale } of the commit `ref` names: refuses (a Refusal) unless
//                            `cwd` is a checkout of one of `repositories` (checkoutRefusal); runs
//                            `git fetch --quiet origin`, whose failure is `stale`, a line for the
//                            answer, not a refusal; then resolves the ref (resolveRef), refusing
//                            one that names no commit
//   checkoutRefusal(cwd, repositories)
//                            why `cwd` is not a checkout of one of `repositories` (owner/name on
//                            GitHub, the first the one named in a refusal), or undefined
//   resolveRef(cwd, ref, repository)
//                            { sha } of the commit `ref` names as origin has it (a branch of
//                            origin's, else origin's tag, by git ls-remote, else a commit's hex),
//                            held by a branch of origin's, or { refusal }
//   git(cwd, args, extra)    one git command, run with childEnv() and GIT_TERMINAL_PROMPT=0 (and
//                            `extra`), bounded at 30 seconds: { ok, stdout, missing }, stdout trimmed
//   refPattern, shaPattern   a ref a tool takes (no leading dash, so no option), and a full sha
//
// The origin is `git config --get remote.origin.url`, the URL as the checkout holds it, never where
// an insteadOf rule sends the fetch, and never printed, since one may carry a token. The fetch and
// resolveRef's ls-remote get SSH_AUTH_SOCK when set, for an ssh origin.
import { spawnSync } from "node:child_process";
import { childEnv, run } from "./children.mjs";
import { Refusal } from "./refusal.mjs";

export const refPattern = /^[A-Za-z0-9_][A-Za-z0-9._/-]{0,199}$/;
export const shaPattern = /^[0-9a-f]{40}([0-9a-f]{24})?$/;
const hexPattern = /^[0-9a-f]{7,64}$/i;

// SSH_AUTH_SOCK when set, for a call that reaches an ssh origin.
const sshAgent = () => (process.env.SSH_AUTH_SOCK === undefined ? {} : { SSH_AUTH_SOCK: process.env.SSH_AUTH_SOCK });

export function git(cwd, args, extra = {}) {
  const ran = spawnSync("git", args, { cwd, env: childEnv({ GIT_TERMINAL_PROMPT: "0", ...extra }), stdio: ["ignore", "pipe", "pipe"], encoding: "utf8", timeout: 30_000 });
  return { ok: !ran.error && ran.status === 0, stdout: (ran.stdout ?? "").trim(), missing: ran.error?.code === "ENOENT" };
}

export function checkoutRefusal(cwd, repositories) {
  const [repository] = repositories;
  const origin = git(cwd, ["config", "--get", "remote.origin.url"]);
  if (origin.missing) return "git is not installed";
  if (!origin.ok || !origin.stdout) return `the working directory is not a git checkout with an origin, so it is not a checkout of ${repository}`;
  // GitHub's host at the URL's start, so no other host or path can end in its name.
  const named = /^(?:https:\/\/(?:[^@/]+@)?|ssh:\/\/git@|git@)github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?\/?$/i.exec(origin.stdout)?.[1];
  if (!named || !repositories.some((known) => known.toLowerCase() === named.toLowerCase())) {
    return `the working directory's origin is not ${repository}`;
  }
  return undefined;
}

// The commit a ref names, as origin has it: a branch of origin's (`<ref>` or `origin/<ref>`), else
// origin's tag, else a commit's hex; never a local branch or tag, so a stale or moved one cannot
// stand in for origin's. Git keeps no remote-tracking tags, so origin's tag is read with
// `git ls-remote` (its peeled commit for an annotated tag), and that commit must be in the checkout;
// when origin's tags cannot be listed, no tag resolves, and the refusal says so.
// The commit must be on a branch of origin's, so one never pushed is not read.
// { sha }, or { refusal }.
export function resolveRef(cwd, ref, repository) {
  const commit = (name) => {
    const resolved = git(cwd, ["rev-parse", "--verify", "--quiet", "--end-of-options", `${name}^{commit}`]);
    return resolved.ok && shaPattern.test(resolved.stdout) ? resolved.stdout : undefined;
  };
  // Whether origin's tags could be listed, so a refusal can say a tag was not read.
  let unlisted = false;
  const originTag = () => {
    const tag = `refs/tags/${ref}`;
    const listed = git(cwd, ["ls-remote", "--tags", "origin", tag], sshAgent());
    if (!listed.ok) {
      unlisted = true;
      return undefined;
    }
    const lines = new Map(listed.stdout.split("\n").map((line) => line.split("\t").reverse()));
    const sha = lines.get(`${tag}^{}`) ?? lines.get(tag);
    return sha && shaPattern.test(sha) ? commit(sha) : undefined;
  };
  const sha =
    commit(`refs/remotes/origin/${ref}`) ??
    (ref.startsWith("origin/") ? commit(`refs/remotes/${ref}`) : undefined) ??
    originTag() ??
    (hexPattern.test(ref) ? commit(ref) : undefined);
  if (!sha && unlisted) {
    return { refusal: `${ref} names no branch of ${repository}'s origin, nor a commit on one of its branches, in this checkout, and origin's tags could not be listed (git ls-remote origin failed), so it was not read as a tag` };
  }
  if (!sha) return { refusal: `${ref} names no branch or tag of ${repository}'s origin, nor a commit on one of its branches, in this checkout` };
  const held = git(cwd, ["for-each-ref", "--count=1", "--format=%(refname)", "--contains", sha, "refs/remotes/origin/"]);
  if (!held.ok || !held.stdout) return { refusal: `${ref} names ${sha.slice(0, 8)}, which no branch of ${repository}'s origin holds in this checkout: only a pushed commit is read` };
  return { sha };
}

export async function commitOf({ cwd, ref, repositories, progress }) {
  const refusal = checkoutRefusal(cwd, repositories);
  if (refusal) throw new Refusal(refusal);
  progress("fetching origin");
  let fetched;
  try {
    const ran = await run("git", ["fetch", "--quiet", "origin"], { cwd, env: childEnv({ GIT_TERMINAL_PROMPT: "0", ...sshAgent() }), timeoutMs: 120_000 });
    fetched = ran.code === 0;
  } catch {
    fetched = false;
  }
  const { sha, refusal: unresolved } = resolveRef(cwd, ref, repositories[0]);
  if (unresolved) throw new Refusal(`${unresolved}${fetched ? "" : ", and git fetch origin failed"}`);
  return { sha, stale: fetched ? "" : "git fetch origin failed, so the ref was read as this checkout last fetched it." };
}
