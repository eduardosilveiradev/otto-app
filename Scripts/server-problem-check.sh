#!/bin/bash
# A failed request to the Mac is named by what went wrong: the status wins over the error it
# caused, offline is told apart from a Mac that can't be reached, and a timeout is its own case.
# Runs Shared/ServerProblem.swift as a plain Swift script (no simulator).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
{ cat Shared/ServerProblem.swift
  cat <<'SWIFT'
let cases: [(Int?, (any Error)?, ServerProblem?)] = [
    (200, nil, nil), (101, nil, nil), (nil, nil, nil),
    (401, nil, .refused), (403, nil, .refused), (500, nil, .server(500)), (503, nil, .server(503)),
    // a websocket turned down at the handshake fails with an error too: the status names it
    (401, URLError(.badServerResponse), .refused), (500, URLError(.badServerResponse), .server(500)),
    (nil, URLError(.notConnectedToInternet), .offline), (nil, URLError(.dataNotAllowed), .offline),
    (nil, URLError(.cannotConnectToHost), .unreachable), (nil, URLError(.cannotFindHost), .unreachable),
    (nil, URLError(.timedOut), .timedOut), (101, URLError(.timedOut), .timedOut),
    (nil, CocoaError(.fileReadUnknown), .unreachable),
]
for (status, error, want) in cases {
    let got = ServerProblem(status: status, error: error)
    precondition(got == want, "status \(String(describing: status)), \(String(describing: error)): got \(String(describing: got)), want \(String(describing: want))")
}
print("server problem ok")
SWIFT
} > "$T"
swift "$T"
