#!/bin/bash
# Coding jobs decode as the server sends them (otto-core's WireJob, in GET /app/jobs and the socket's
# "jobs" frame): fields this app doesn't read are ignored, ones an older server leaves out fall back,
# and a job that won't decode is left out without losing the rest. Runs the model code from
# Jobs.swift as a plain Swift script (no simulator).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
{ echo 'import Foundation'
  sed -n '/^struct CodeJob:/,/^}/p; /^extension CodeJob.Question: Decodable/,/^}/p; /^extension CodeJob: Decodable/,/^}/p; /^struct CodeJobs/,/^}/p' Otto/Jobs.swift
  cat <<'SWIFT'
let wire = #"""
{"type":"jobs","github":{"reachable":true},"usage":{"jobsToday":3,"tokensToday":1200000,"tokenBudget":5000000},"jobs":[
 {"id":"a","state":"running","t3Status":"running","threadId":"t1","threadUrl":null,"title":"Compare the quotes","project":"home","branch":"otto/quotes",
  "agent":"claude","where":"local","model":null,"createdAt":"2026-11-15T08:00:00Z","startedAt":"2026-11-15T08:01:00Z","endedAt":null,
  "tokensUsed":1200,"tokenBudget":50000,"now":"Reading the second quote","question":null,"council":[],
  "steps":[{"ts":"2026-11-15T08:02:00Z","text":"Read the PDFs"},{"ts":"2026-11-15T08:05:00Z","text":"Built the table","note":"three rows"}],"pr":null},
 {"id":"b","state":"input","title":"Rename the keys","question":{"text":"Rename both?","answers":["Rename both","Keep both"],"askedAt":"2026-11-15T08:10:00Z"}},
 {"id":"c","state":"review","title":"Quieter route","pr":{"n":214,"title":"A quieter route","url":"https://example.com/pull/214","add":81,"del":4,"files":3,
  "mergeable":"CONFLICTING","base":"main","checks":"passing","draft":false,"diff":[{"file":"a.ts","hunk":"@@","lines":[["+","x"]]}]}},
 {"id":"d","state":"review","pr":{"n":7}},
 {"state":"running","title":"no id: left out"},
 {"id":"e","state":"input","question":{"text":"No answers offered"}},
 "not a job at all"
]}
"""#
let w = try! JSONDecoder().decode(CodeJobs.self, from: Data(wire.utf8))
assert(w.jobs.map(\.id) == ["a", "b", "c", "d", "e"], "\(w.jobs.map(\.id))")
let a = w.jobs[0], b = w.jobs[1], c = w.jobs[2], d = w.jobs[3], e = w.jobs[4]
assert(a.working && !a.needsYou && a.steps.count == 2 && a.steps[1].note == "three rows" && a.pr == nil && a.question == nil)
assert(a.project == "home" && a.now == "Reading the second quote" && a.startedAt == "2026-11-15T08:01:00Z" && a.endedAt == nil)
assert(b.needsYou && !b.working && b.question?.answers == ["Rename both", "Keep both"] && b.steps.isEmpty && b.project == nil)
assert(c.conflicts && !c.canMerge && c.pr?.n == 214 && c.pr?.add == 81 && c.pr?.base == "main")
assert(d.canMerge && !d.conflicts && d.title == "" && d.pr?.mergeable == nil)   // an older server sends no `mergeable`: it doesn't block
assert(e.needsYou && e.question?.text == "No answers offered" && e.question?.answers == [])
// a frame with no list, and one that isn't a list, are both no jobs rather than an error
assert(try! JSONDecoder().decode(CodeJobs.self, from: Data(#"{"type":"jobs"}"#.utf8)).jobs.isEmpty)
assert(try! JSONDecoder().decode(CodeJobs.self, from: Data(#"{"jobs":"none"}"#.utf8)).jobs.isEmpty)
// one action's answer is the job itself
let one = try! JSONDecoder().decode(CodeJob.self, from: Data(#"{"id":"c","state":"merged","title":"Quieter route","cost":"2.1M Claude tokens"}"#.utf8))
assert(one.over && one.cost == "2.1M Claude tokens" && !one.canMerge)
print("jobs ok")
SWIFT
} > "$T"
swift "$T"
