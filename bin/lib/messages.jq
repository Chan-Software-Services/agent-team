# A worker's message, read whole into the events the coordinator's message table gives it, for
# team-log --from-message. Every value is the raw text the message wrote (a comma list, key:value
# counts, a JSON object), which team-log then types and checks as it does a hand-typed key=value.
include "ledger";

# The forms a message takes after its task, as the role prompts and brief templates write them.
def message_forms:
  ["QUESTION <text>", "BLOCKED <what> <why>", "BLOCKED <what> <why>; took its allowed way [<way>]",
   "NEED toolkit <name>",
   "PAUSED <why>",
   "PR <full url> [merged <base> conflicts: <files or none>]",
   "DONE <NN> <sha>... <line>", "DONE review-ready <sha>", "DONE merged <base> <sha> conflicts: <files or none>",
   "DONE pass <PR url or head> findings=<kind:n,...> [before=<list>] guarded=<list> [widening=<list>] [memory=<path>]",
   "DONE findings <path> findings=<kind:n,...> [before=<list>] guarded=<list> [widening=<list>] [memory=<path>]",
   "DONE gate <key=value>...", "DONE <report>", "FAILED <why>", "INJECTION <where> <what it asked>"];

def message_sha: test("^[0-9a-f]{7,40}$");
def message_pr_url: test("^https://github\\.com/[^/\\s]+/[^/\\s]+/pull/[0-9]+/?$");

# A refusal of the message, which nothing is logged after.
def message_refused($why): {problems: [$why]};

# The key=value pairs of a text, each value running to the next " <key>=" so that a JSON object
# with spaces stays one value: [[key, value]...], or a refusal naming the malformed part; $what
# names the message's form in it.
def message_pairs($what):
  . as $text
  | [match("(?:^|\\s)([a-z][a-z0-9_]*)="; "g")] as $ms
  | if $ms == [] then message_refused("\($what) takes key=value pairs, got '\($text)'")
    elif ($text[:$ms[0].offset] | test("\\S")) then
      message_refused("\($what) takes key=value pairs, got '\($text[:$ms[0].offset] | gsub("^\\s+|\\s+$"; ""))' before the first")
    else
      [range($ms | length) as $i | $ms[$i] as $m
        | [$m.captures[0].string,
           ($text[$m.offset + $m.length:(if $i + 1 < ($ms | length) then $ms[$i + 1].offset else ($text | length) end)]
            | gsub("^\\s+|\\s+$"; ""))]] as $pairs
      | ([$pairs[] | select(.[1] == "") | .[0]] | first) as $empty
      | ([$pairs[] | .[0]] | group_by(.) | map(select(length > 1) | first) | first) as $twice
      | if $empty != null then message_refused("\($what) has \($empty)= with no value")
        elif $twice != null then message_refused("\($what) has \($twice)= twice")
        else {pairs: $pairs} end
    end;

# The task's launches, each with its index in the events: $events | message_launches
def message_launches: [to_entries[] | select(.value.event == "launch") | .value + {i: .key}];

# A launch's session name, as team-worker names it: "T7-builder", "T7-builder-03" for a builder in
# ticket 03's worktree.
def message_session_name($task): "\($task)-\(.role)" + if .ticket != null then "-\(.ticket)" else "" end;

# A launch's session name and id, as a refusal names it: "T7-builder (b0000001)".
def message_launch_name($task): "\(message_session_name($task)) (\(.session))";

# The latest launch of each role and ticket (none, or a ticket builder's) with no event since that
# ends it (ends_launch): the workers whose message has not been reported yet.
def message_unreported($events):
  $events | message_launches | group_by([.role, .ticket]) | map(max_by(.i))
  | map(. as $l | select(all($events[$l.i + 1:][]; ends_launch($l) | not))) | sort_by(.i);

# The message's sender: {role, session, brief...} of --from's launch ($from, a session name
# T<n>-<role> or T<n>-<role>-<NN>, or a launch's session id, or "": the latest launch it names),
# its role checked against the one the kind implies ($implied, or null); else of the latest launch
# of $implied, for a builder's DONE <NN> ($ticket, else null) the latest builder launch of ticket
# NN when there is one; else of the only launch with no report since; or a refusal.
def message_sender($task; $events; $from; $implied; $ticket):
  ($events | message_launches) as $launches
  | def latest($role): $launches | map(select(.role == $role)) | last;
    def from_launch:
      if $from == "" then null
      else ($launches | map(select(message_session_name($task) == $from or .session == $from)) | last) as $l
        | if $l != null then $l
          else {problems: ["--from \($from) names no launch of \($task)"
            + if $launches == [] then ": it has none"
              else ": its sessions are " + ($launches | group_by([.role, .ticket]) | map(max_by(.i)) | sort_by(.i)
                | map(message_launch_name($task)) | join(", ")) end]} end end;
    from_launch as $named
    | if $named.problems then $named
      elif $implied != null then
        if $named != null and $named.role != $implied then
          message_refused("the message is a \($implied)'s, but --from names \($named | message_session_name($task))")
        elif $named != null then {sender: $named}
        else ((if $ticket != null then $launches | map(select(.role == $implied and .ticket == $ticket)) | last else null end)
              // latest($implied)) as $l
          | if $l == null then message_refused("the message is a \($implied)'s, but \($task) has no \($implied) launch")
            else {sender: $l} end end
      elif $named != null then {sender: $named}
      else message_unreported($events) as $open
        | if ($open | length) == 1 then {sender: $open[0]}
          elif $launches == [] then
            message_refused("the message's sender is not known: \($task) has no launch; name it with --from <session>")
          elif $open == [] then
            message_refused("the message's sender is not known: every launch of \($task) has a report since; name it with --from <session>")
          else message_refused("the message's sender is not known: "
            + ($open | map(message_launch_name($task)) | .[:-1] | join(", ")) + " and "
            + ($open | last | message_launch_name($task)) + " have no report since their launch; name it with --from <session>")
          end end;
def message_sender($task; $events; $from; $implied): message_sender($task; $events; $from; $implied; null);

# Runs f on the sender's {sender} when it is known, passing a refusal through; $ticket is
# message_sender's.
def with_sender($task; $events; $from; $implied; $ticket; f):
  message_sender($task; $events; $from; $implied; $ticket) as $s
  | if $s.problems then $s else $s.sender | f end;
def with_sender($task; $events; $from; $implied; f): with_sender($task; $events; $from; $implied; null; f);

# One event: {event, fields: [[key, raw value]...]}.
def message_event($event; $fields): {event: $event, fields: $fields};

# A worker's park, a blocked or a paused of cause $cause with reason $reason, carrying the sender's
# role and session when message_sender names one, and neither when it cannot tell the sender (a
# launch of any role then ends the park); a --from that names no launch is refused.
def message_park($task; $events; $from; $kind; $cause; $reason):
  message_sender($task; $events; $from; null) as $s
  | if $s.problems and $from != "" then $s
    else {events: [message_event($kind; [["reason", $reason], ["cause", $cause]]
      + if $s.sender then [["role", $s.sender.role], ["session", $s.sender.session]] else [] end)]} end;

# A BLOCKED's text read as <body>; took its allowed way [<way>]: {body, way}, way null when the
# marker ends the text, or null when the text is no such form. The marker follows a semicolon and
# ends the text or comes before the way: a parenthesis, or a clause after a comma, a colon or a
# blank and a dash, the separator and the blanks around the way no part of it. The marker
# mid-sentence, with no semicolon before it or a word after it, is no such form.
def message_went_past:
  capture("^(?<body>.*?)\\s*;\\s*took its allowed way(?:(?:\\s*[,:]|\\s+-+(?=\\s)|\\s*(?=\\())\\s*(?<way>.*?))?\\s*$"; "s") // null;

# A worker's BLOCKED <what> <why>; took its allowed way [<way>] ($rest, the text after BLOCKED, and
# $went, message_went_past's reading of it): a refusal that named an allowed way, which the
# worker took and went on by. Its denied carries the sender's role and session (refused when
# the sender cannot be told, as a QUESTION's), what the body's first word, why the rest, and way
# the text after the marker when there is any; it parks nothing.
def message_denied($task; $events; $from; $rest; $went):
  ($went.body | capture("^(?<what>\\S+)\\s+(?<why>\\S.*)$"; "s") // null) as $d
  | if $d == null then
      message_refused("BLOCKED takes 'BLOCKED <what> <why>; took its allowed way [<way>]', got 'BLOCKED \($rest)'")
    else with_sender($task; $events; $from; null;
      {events: [message_event("denied"; [["role", .role], ["what", $d.what], ["why", $d.why], ["session", .session]]
        + if ($went.way // "") != "" then [["way", $went.way]] else [] end)]}) end;

# The cause of a worker's PAUSED <why>, by its first word (any case): stowed a stow, the answer to
# STOW; held coordinator-hold, the answer to HOLD; offline offline, GitHub out of reach; any other
# worker.
def message_paused_cause:
  (first(capture("^(?<w>\\w+)") | .w | ascii_downcase) // "") as $word
  | {stowed: "stow", held: "coordinator-hold", offline: "offline"}[$word] // "worker";

# The project a reviewer's verdict is of: $pr_project, the project of the PR a DONE pass names,
# when it is known (not ""); else the project of the reviewer launch --from names ($from, a session
# id or name), else of the task's latest reviewer launch; "" when that launch names none.
def message_verdict_project($task; $events; $from; $pr_project):
  ($events | message_launches | map(select(.role == "reviewer"))) as $ls
  | (if $from == "" then null else $ls | map(select(.session == $from or message_session_name($task) == $from)) | last end) as $named
  | if $pr_project != "" then $pr_project else ($named // ($ls | last)).project // "" end;

# The task's reviewer launches in $project, in ledger order: each whose project is $project or
# that names none, and every one when $project is "".
def message_project_reviewers($events; $project):
  $events | message_launches | map(select(.role == "reviewer" and ($project == "" or .project == null or .project == $project)));

# On a project whose agent-review the reviewer App posts, a verdict is taken only with --from
# naming the session id of the latest reviewer launch in the verdict's project
# (message_verdict_project, message_project_reviewers), the session the coordinator saw the
# message come from, so the reviews of a task's PRs in two repositories run beside each other and
# a later launch in one repository leaves the other's verdict standing. $apps are the task's
# projects the App posts for; with no project known, the first of them stands for it. Null when
# --from names that session (or the task has no reviewer launch, which message_sender refuses),
# else a refusal naming that session, or that the project has no reviewer launch. The name
# T<n>-reviewer is refused there too, since it names a role and not the session. The refusal says
# "in <project>" only when the task's reviewer launches name more than one project.
# When they do, and the App posts for one of those projects, a verdict whose project neither a
# PR nor --from gives ($pr_project and $from both "") could be either repository's reviewer's, so
# it is refused naming each project's latest reviewer session, never taken as the latest launch's.
def message_app_sender($task; $events; $from; $apps; $pr_project):
  message_verdict_project($task; $events; $from; $pr_project) as $project
  | (if $project == "" then $apps[0] // "" elif any($apps[]; . == $project) then $project else "" end) as $app
  | ($events | message_launches | map(select(.role == "reviewer"))) as $all
  | (message_project_reviewers($events; $project) | last) as $l
  | ([$all[] | .project | strings] | unique) as $projects
  | (if ($projects | length) > 1 then " in \($project)" else "" end) as $where
  | if $from == "" and $pr_project == "" and ($projects | length) > 1 and any($projects[]; IN($apps[])) then
      message_refused("the reviewer App posts agent-review on \(first($projects[] | select(IN($apps[])))), and \($task)'s reviewers were launched in "
        + ($projects | .[:-1] | join(", ")) + " and \($projects | last), so the verdict's project is not known: "
        + "run it again with --from <session> once the message came from that session, "
        + ([$projects[] as $p | ($all | map(select(.project == $p)) | last) | "\(message_launch_name($task)) in \($p)"] | join(" or ")))
    elif $app == "" or $all == [] or ($l != null and $from == $l.session) then null
    elif $l == null then
      message_refused("the reviewer App posts agent-review on \($app), so its verdict is taken only from a reviewer session in \($project), and \($task) has launched none there")
    else "\($task)'s latest reviewer session\($where), \($l | message_launch_name($task))" as $latest
      | "the reviewer App posts agent-review on \($app), so its verdict is taken only from" as $why
      | if $from == "" then
          message_refused("\($why) \($latest): run it again with --from \($l.session) once the message came from that session")
        else message_refused("--from \($from) is not \($latest): \($why) that session") end end;

# A reviewer's DONE pass or findings: the review and the reviewer's done, the review carrying
# widening=, the numbers of a rereview's new findings in what the last fix added, and memory=, the
# file of memories the reviewer added for the coordinator to file, when it names them.
# Its sender is checked by message_app_sender first. With no --from, a pass naming a PR whose
# project is known ($pr_project) is its latest reviewer launch's when it has one, and a sender
# launched in another project than that PR's is refused, so one repository's review is never
# logged on another's head.
# Its head is the head of the brief record its latest launch read ($records, by brief name), else
# the message's own head for a pass on a head, else it is refused naming head=. Its verdict is the
# message's word, raw:
# team-log types the event and logs a pass whose sent_back names any finding as findings
# (review_sent_back in ledger.jq), as it does a review logged by hand.
def message_review($task; $events; $records; $from; $sent_back; $apps; $pr_project; $verdict; $rest):
  ($rest | capture("^(?<target>\\S+)(?:\\s+(?<pairs>.*))?$"; "s") // null) as $m
  | message_app_sender($task; $events; $from; $apps; $pr_project) as $refused
  | (if $from != "" or $pr_project == "" then $from
     else (message_project_reviewers($events; $pr_project) | last | .session) // "" end) as $from
  | if $refused != null then $refused
    elif $m == null or ($m.pairs // "") == "" then message_refused("DONE \($verdict) needs findings= and guarded=")
    elif $verdict == "pass" and ($m.target | (message_sha or message_pr_url) | not) then
      message_refused("DONE pass takes a PR url or a head of 7 to 40 hex digits, got '\($m.target)'")
    else ($m.pairs | message_pairs("DONE \($verdict)")) as $p
      | if $p.problems then $p
        elif any($p.pairs[]; .[0] | IN("findings", "before", "guarded", "widening", "memory") | not) then
          message_refused("DONE \($verdict) takes findings=<kind:n,...>, before=<list>, guarded=<list>, widening=<list> and memory=<path>, got "
            + ([$p.pairs[] | .[0] | select(IN("findings", "before", "guarded", "widening", "memory") | not)] | join(", ")))
        elif ([$p.pairs[] | .[0] | select(IN("findings", "guarded"))] | length) < 2 then
          message_refused("DONE \($verdict) needs findings= and guarded=")
        else with_sender($task; $events; $from; "reviewer";
          . as $l
          | ($records[$l.brief // ""].values.head // null) as $recorded
          | (if $recorded != null then $recorded
             elif $verdict == "pass" and ($m.target | message_sha) then $m.target
             else null end) as $head
          | if $pr_project != "" and $l.project != null and $l.project != $pr_project then
              message_refused("DONE pass names \($m.target), a PR of \($pr_project), but \($l | message_launch_name($task)) was launched in \($l.project)")
            elif $head == null then
              message_refused("the review's head is not known: the reviewer's latest launch (\($l.session)) "
                + (if $l.brief then "read \($l.brief), which has no record with a head" else "read no brief" end)
                + ", and DONE \($verdict) "
                + (if $verdict == "pass" then "names \($m.target), not a head" else "names no head" end)
                + "; log the review by hand with head=<the full sha reviewed>")
            else {events: [
              message_event("review"; [["verdict", $verdict], ["head", $head]] + $p.pairs
                + if $sent_back == "" then [] else [["sent_back", $sent_back]] end),
              message_event("done"; [["role", "reviewer"], ["session", $l.session]])]} end)
        end
    end;

# A builder's DONE <NN> <sha>... <line>: the ticket-done and the done of ticket NN's builder
# (message_sender).
def message_ticket($task; $events; $from; $ticket; $rest):
  ($rest | [splits("\\s+")]) as $words
  | ([$words | to_entries[] | select(.value | message_sha | not) | .key] | first // ($words | length)) as $n
  | if $n == 0 then
      message_refused("DONE \($ticket) takes one or more shas of 7 to 40 hex digits after the ticket, then a line, got '\($words[0] // "")'")
    else ($rest | sub("^\\s*(\\S+\\s*){\($n)}"; "")) as $line
      | with_sender($task; $events; $from; "builder"; $ticket;
          {events: [
            message_event("ticket-done"; [["ticket", $ticket], ["commits", ($words[:$n] | join(","))]]
              + if $line == "" then [] else [["note", $line]] end),
            message_event("done"; [["role", "builder"], ["session", .session]])]})
    end;

# The builder's done for a DONE whose report it carries whole.
def message_builder_done($task; $events; $from; $report):
  with_sender($task; $events; $from; "builder"; {events: [message_event("done"; [["role", "builder"], ["session", .session], ["report", $report]])]});

# An ops session's DONE or QUESTION, whose text may hold production data: its event with the
# text's length in characters (report_chars, chars) and never the text, marked ops: true, the mark
# message_one_line takes a message of more than one line by and parse_message drops.
def message_ops($event; $l; $text):
  if $event == "done" then
    {events: [message_event("done"; [["role", "ops"], ["session", $l.session], ["report_chars", ($text | length | tostring)]])], ops: true}
  else {events: [message_event("question"; [["role", "ops"], ["chars", ($text | length | tostring)]])], ops: true} end;

# Whether --from ($from) names an ops session of the task, which takes its DONE whatever its
# first word.
def message_from_ops($task; $events; $from):
  $from != "" and (message_sender($task; $events; $from; null) | .sender.role? == "ops");

# A DONE: an ops session's when --from names one, else the forms above by their first word, else
# the sender's done with its report, or an ops sender's with its length.
def message_done($task; $events; $records; $from; $sent_back; $apps; $pr_project; $rest):
  ($rest | capture("^(?<word>\\S+)(?:\\s+(?<more>.*))?$"; "p")) as $d
  | ($d.more // "") as $more
  | if message_from_ops($task; $events; $from) then
      with_sender($task; $events; $from; null; message_ops("done"; .; $rest))
    elif ($d.word | test("^[0-9]{2}$")) then message_ticket($task; $events; $from; $d.word; $more)
    elif $d.word == "review-ready" then
      if ($more | message_sha) then message_builder_done($task; $events; $from; $rest)
      else message_refused("DONE review-ready takes 'DONE review-ready <sha>', got 'DONE \($rest)'") end
    elif $d.word == "merged" then
      if ($more | test("^\\S+\\s+[0-9a-f]{7,40}\\s+conflicts:\\s*\\S"; "s")) then message_builder_done($task; $events; $from; $rest)
      else message_refused("DONE merged takes 'DONE merged <base> <sha> conflicts: <files or none>', got 'DONE \($rest)'") end
    elif $d.word == "pass" or $d.word == "findings" then
      message_review($task; $events; $records; $from; $sent_back; $apps; $pr_project; $d.word; $more)
    elif $d.word == "gate" then
      ($more | message_pairs("DONE gate")) as $p
      | if $p.problems then $p else {events: [message_event("gate-run"; $p.pairs)]} end
    else with_sender($task; $events; $from; null;
      if .role == "ops" then message_ops("done"; .; $rest)
      else {events: [message_event("done"; [["role", .role], ["session", .session], ["report", $rest]])]} end) end;

# A message of more than one line ($text, of kind $kind), read (the input, parse_message's reading
# of it, {} for a kind that may not run on): taken when it is an ops session's DONE or QUESTION
# (message_ops' reading, known by its mark, never by a field name the message may write itself:
# its length alone, so the answer of several lines the coordinator relays to Discord goes through
# as it was sent), else refused saying a message is one line, never with its text.
# Every other kind's text is one line: the ledger keeps it, and its views (state_line,
# retro_digest_text) print it within one line. A DONE or QUESTION whose sender cannot be told, on
# a task with an ops launch, may be that session's, so the refusal names message_sender's reason,
# which says how to name it.
def message_one_line($task; $events; $from; $kind; $text):
  if .ops == true then .
  else (message_sender($task; $events; $from; null) | .problems // [] | first) as $unknown
    | message_refused("a worker's message is one line, but for an ops session's DONE or QUESTION, and this \($kind) has "
      + "\($text | [splits("\n")] | length) lines; "
      + if $unknown != null and ($kind | IN("DONE", "QUESTION")) and any($events[]; .event == "launch" and .role == "ops")
        then "it may be an ops session's, but \($unknown)" else "log it on one line" end) end;

# The message (the input) of $task read into {events: [{event, fields}...]}, or {problems}. Its
# task and kind are read from its first line alone, and its capture's flag p lets its rest run past
# a newline, a message that does taken or refused by message_one_line; a message of more than one
# line whose first line is not its task and kind is refused without its text, which may be an ops
# answer. $events are the task's events, $records its brief records by name (brief-review:
# {template, project, values}), $from the --from session or "", $sent_back the --sent-back list or "", $apps the
# task's projects whose agent-review the reviewer App posts, and $pr_project the project of the PR
# a DONE pass names, or "" (message_app_sender). A pr event's head is left for the caller to read from
# GitHub: it carries github: <url> and no head.
def parse_message($task; $events; $records; $from; $sent_back; $apps; $pr_project):
  gsub("^\\s+|\\s+$"; "") as $text
  | ($text | capture("^(?<task>T[0-9]+)[ \\t]+(?<kind>\\S+)(?:\\s+(?<rest>.*))?$"; "p") // null) as $m
  | ($m.rest // "") as $rest
  | def unreadable: message_refused("cannot read '\($text)': expected one of \(message_forms | join(", "))");
    def read:
    if $m.kind == "QUESTION" then
      with_sender($task; $events; $from; null;
        if .role == "ops" then message_ops("question"; .; $rest)
        else {events: [message_event("question"; [["role", .role], ["text", $rest]])]} end)
    elif $m.kind == "BLOCKED" then
      ($rest | message_went_past) as $went
      | if $went != null then message_denied($task; $events; $from; $rest; $went)
        else message_park($task; $events; $from; "blocked"; "worker"; $rest) end
    elif $m.kind == "NEED" then
      if ($rest | test("^toolkit\\s+\\S+$")) then message_park($task; $events; $from; "blocked"; "worker"; "needs " + ($rest | sub("\\s+"; " ")))
      else message_refused("NEED takes 'NEED toolkit <name>', got 'NEED \($rest)'") end
    elif $m.kind == "PAUSED" then message_park($task; $events; $from; "paused"; $rest | message_paused_cause; $rest)
    elif $m.kind == "PR" then
      ($rest | capture("^(?<url>\\S+)(?:\\s+merged\\s+\\S+\\s+conflicts:\\s*\\S.*)?$"; "s") // null) as $pr
      | if $pr == null or ($pr.url | message_pr_url | not) then
          message_refused("PR takes 'PR <full url>', optionally followed by 'merged <base> conflicts: <files or none>', got 'PR \($rest)'")
        else {events: [message_event("pr"; [["url", $pr.url]]) + {github: $pr.url}]} end
    elif $m.kind == "DONE" then message_done($task; $events; $records; $from; $sent_back; $apps; $pr_project; $rest)
    elif $m.kind == "FAILED" then {events: [message_event("failed"; [["reason", $rest]])]}
    elif $m.kind == "INJECTION" then
      ($rest | capture("^(?<source>\\S+)\\s+(?<text>\\S.*)$"; "s") // null) as $i
      | if $i == null then message_refused("INJECTION takes 'INJECTION <where> <what it asked>', got 'INJECTION \($rest)'")
        else with_sender($task; $events; $from; null;
          {events: [message_event("injection"; [["role", .role], ["source", $i.source], ["text", $i.text]])]}) end
    else unreadable end;
    (if $m == null and ($text | test("\n")) then
      message_refused("a worker's message starts with its task, \($task), then its kind, on its first line; "
        + "got a message of \($text | [splits("\n")] | length) lines that does not")
    elif $m == null or ($text | test("^T[0-9]+[ \\t]") | not) then
      message_refused("a worker's message starts with its task, \($task), then its kind; got '\($text)'")
    elif $m.task != $task then message_refused("the message is for \($m.task), not \($task)")
    elif $sent_back != "" and ($m.kind != "DONE" or ($rest | test("^(findings|pass)(\\s|$)") | not)) then
      message_refused("--sent-back is taken only with a DONE findings or DONE pass message, not "
        + (if $m.kind == "DONE" then "DONE " + ([$rest | splits("\\s+")][0]) else $m.kind end))
    elif $rest == "" then unreadable
    elif ($text | test("\n") | not) then read
    elif $m.kind | IN("DONE", "QUESTION") then read | message_one_line($task; $events; $from; $m.kind; $text)
    else {} | message_one_line($task; $events; $from; $m.kind; $text) end) | del(.ops);

# The parsed message (parse_message's, of the message $message) with --relay's id ($relay, or "")
# on its ops session's done, the pointer to the coordinator's relay of its answer in Discord; any
# other message is refused with it, naming its kind and its sender when it has one. An ops done is
# known by its done event's role ops, as message_ops writes it, never by a field name such as
# report_chars, which a message may write itself (a DONE gate's pairs).
def message_relay($task; $message; $relay):
  if $relay == "" or .problems then .
  else [.events[] | .fields | map({key: .[0], value: .[1]}) | from_entries] as $fields
    | if any(.events[]; .event == "done" and any(.fields[]; . == ["role", "ops"])) then
        .events |= map(if .event == "done" then .fields += [["relay", $relay]] else . end)
      else ($message | gsub("^\\s+"; "") | [splits("\\s+")][1]) as $kind
        | ([$fields[] | .role | strings] | first) as $role
        | message_refused("--relay is taken only with an ops session's DONE, the answer it points at in Discord, not "
          + if $role != null then "\($task)-\($role)'s \($kind)" else $kind end) end
  end;
