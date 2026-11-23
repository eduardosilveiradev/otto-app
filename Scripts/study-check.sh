#!/bin/bash
# A study set's saved place: keyed by its content (same set resumes, an edited one starts fresh),
# reset when the stored counts don't match, and which side of a card is up isn't kept. Runs the
# model code from Study.swift as a plain Swift script (no simulator).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
{ echo 'import Foundation'; echo 'import CryptoKit'
  echo 'struct RemoteFile { let name: String }'
  sed -n '/^struct StudySet: Codable/,/^}/p' Otto/Study.swift
  sed -n '/^struct StudyProgress: Codable/,/^}/p; /^struct CardsRun: Codable/,/^}/p; /^struct QuizRun: Codable/,/^}/p' Otto/Study.swift
  cat <<'SWIFT'
let d = UserDefaults(suiteName: "dev.otto.study-check")!
d.removePersistentDomain(forName: "dev.otto.study-check")
let j = #"{"title":"Tiny","cards":[{"front":"1+1","back":"2"},{"front":"2+2","back":"4"}],"quiz":[{"q":"3+3?","options":["5","6"],"answer":1}]}"#
let reordered = #"{ "quiz":[{"answer":1,"options":["5","6"],"q":"3+3?"}],  "cards":[{"back":"2","front":"1+1"},{"back":"4","front":"2+2"}], "title":"Tiny" }"#
let edited = j.replacingOccurrences(of: #""4""#, with: #""5""#)
func set(_ s: String) -> StudySet { try! JSONDecoder().decode(StudySet.self, from: Data(s.utf8)) }
let a = set(j)
assert(a.key == set(reordered).key, "same content, other key order or spacing: same key")
assert(a.key != set(edited).key, "an edited set gets its own key")

// Nothing stored: fresh, sized to the set.
assert(a.progress(in: d) == StudyProgress(size: [2, 1]) && a.progress(in: d).isEmpty)

// Saved and read back; the flip isn't kept.
var p = a.progress(in: d)
p.mode = 1; p.cards.flipped = true; p.cards.known = [0]; p.cards.queue = [1]; p.quiz.answered = [0: 1]; p.quiz.at = 1; p.sent = "r"
a.save(p, in: d)
var back = a.progress(in: d)
assert(!back.cards.flipped && back.cards.known == [0] && back.cards.queue == [1] && back.quiz.answered == [0: 1] && back.quiz.at == 1 && back.mode == 1 && back.sent == "r")
back.cards.flipped = true; assert(back == p)
assert(set(reordered).progress(in: d) == a.progress(in: d) && !a.progress(in: d).isEmpty, "the same set sent again resumes")
assert(set(edited).progress(in: d).isEmpty, "an edited set starts fresh")

// Stored counts that no longer match reset (they'd index past the end).
var stale = p; stale.size = [3, 1]
a.save(stale, in: d)
assert(a.progress(in: d) == StudyProgress(size: [2, 1]))

// Two sets don't collide; zero cards and zero questions are fine.
let noCards = set(#"{"title":"Q","cards":[],"quiz":[{"q":"x","options":["a"],"answer":0}]}"#)
let noQuiz = set(#"{"title":"C","cards":[{"front":"f","back":"b"}],"quiz":[]}"#)
var q = noCards.progress(in: d); q.quiz.answered = [0: 0]; noCards.save(q, in: d)
assert(noCards.progress(in: d).quiz.answered == [0: 0] && noQuiz.progress(in: d) == StudyProgress(size: [1, 0]))
assert(a.progress(in: d).isEmpty)

// A long set round-trips.
let long = StudySet(title: "Long", source: nil, cards: (0..<2000).map { .init(front: "\($0)", back: "b") }, quiz: [])
var l = long.progress(in: d); l.cards.known = Set(0..<1500); l.cards.queue = Array(1500..<2000); long.save(l, in: d)
assert(long.progress(in: d).cards.known.count == 1500)
print("study progress ok")
SWIFT
} > "$T"
swift "$T"
defaults delete dev.otto.study-check >/dev/null 2>&1 || true   # the throwaway suite the check wrote
