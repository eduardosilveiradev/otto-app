import Foundation

/// Canned /app/dash/* answers for MockBackend, so every contact-card page has something
/// to show (and to screenshot) without a server. Shapes follow the wire types in Dash.swift.
enum MockDash {
    static func data(_ path: String) -> Data? {
        #if DEBUG
        // `-emptyDash`: every list empty, for the empty states. `-mockCalls`: Otto on a live call.
        if CommandLine.arguments.contains("-emptyDash"), let e = empty[path] { return Data(e.utf8) }
        if path == "calls" { return CommandLine.arguments.contains("-mockCalls") ? Data(calls.utf8) : nil }
        #endif
        return json[path].map { Data($0.utf8) }
    }

    #if DEBUG
    private static let empty: [String: String] = [
        "loops": #"{"open":[],"plan":{"close":[],"propose":[],"avoidance":[]},"recent":[]}"#,
        "jobs": #"{"jobs":[]}"#, "capabilities": #"{"entries":[]}"#, "triggers": #"{"triggers":[]}"#,
        "calls": #"{"calls":[]}"#, "packages": #"{"packages":[]}"#,
        "trips": #"{"trips":[],"current":null,"problems":{}}"#, "people": #"{"cards":[]}"#,
    ]

    private static var calls: String {
        let now = Date().timeIntervalSince1970 * 1000
        return """
        {"calls":[
          {"id":"c1","to":"+1 555 0142","task":"Book a table for two at 19:30 on Friday","status":"in-progress","seq":6,"createdAt":\(now - 95_000),"startedAt":\(now - 80_000),"endedAt":null,"endedReason":null,"takeover":false,"partial":{"user":"We have a table at"},
           "lines":[{"role":"assistant","text":"Hi, I'm calling to book a table for two this Friday."},{"role":"user","text":"Sure, what time were you thinking?"},{"role":"assistant","text":"Half past seven, if you have it."}]},
          {"id":"c2","to":"+1 555 0199","task":"Ask the bike shop if the repair is ready","status":"ended","seq":4,"createdAt":\(now - 3_000_000),"startedAt":\(now - 2_990_000),"endedAt":\(now - 2_900_000),"endedReason":"customer-ended-call","takeover":false,"partial":{},
           "lines":[{"role":"assistant","text":"Hi, is the blue bike under the name Sam ready?"},{"role":"user","text":"Yes, ready after 4."}]}]}
        """
    }
    #endif

    private static let json: [String: String] = [
        "loops": """
        {"open":[
          {"id":"l1","text":"Pay electric bill, €112","tags":["money"],"createdAt":"2026-11-01T09:00:00Z","due":"2026-11-07","status":"open"},
          {"id":"l2","text":"Reply to the landlord about the boiler","tags":["home"],"createdAt":"2026-11-02T18:20:00Z","status":"open","deferrals":["2026-11-03","2026-11-04"]},
          {"id":"l3","text":"Waiting on passport renewal","tags":["waiting"],"createdAt":"2026-10-20T10:00:00Z","status":"open"},
          {"id":"l4","text":"Send Marta the slides from Thursday","tags":["work"],"createdAt":"2026-11-03T16:00:00Z","due":"2026-11-05","status":"open"}],
         "plan":{"close":[{"id":"l3","status":"done","reason":"The passport office emailed: ready for pickup."}],
                 "propose":[{"id":"p1","text":"Book the dentist for Tuesday after 16:00","reason":"You asked twice this week."}],
                 "avoidance":[{"id":"l2","text":"Reply to the landlord about the boiler","deferrals":2}]},
         "recent":[{"id":"l9","text":"Renew gym membership","tags":[],"createdAt":"2026-10-28T08:00:00Z","status":"done","closedReason":"Paid on the 2nd","closedBy":"otto","closedAt":"2026-11-02T08:10:00Z"}]}
        """,
        "memory": """
        {"items":[
          {"id":"m1","store":"facts","kind":"preference","scope":"me","name":"Coffee order","description":"Flat white, oat milk. No sugar.","updated":"2026-11-01T08:00:00Z","hits":14,"lastHitDays":1},
          {"id":"m2","store":"facts","kind":"person","scope":"me","name":"Marta","description":"Design lead. Prefers Slack to email, mornings.","updated":"2026-10-30T12:00:00Z","hits":9,"lastHitDays":2},
          {"id":"m3","store":"facts","kind":"place","scope":"me","name":"Dentist","description":"Studio Bianchi, Via Roma 12. Tuesdays after 16:00.","updated":"2026-10-21T12:00:00Z","hits":3,"lastHitDays":6},
          {"id":"m4","store":"facts","kind":"routine","scope":"me","name":"Boiler service","description":"Every November. Landlord books, you let them in.","updated":"2026-10-12T12:00:00Z","hits":2,"lastHitDays":20},
          {"id":"m5","store":"facts","kind":"fact","scope":"me","name":"Wi-Fi at the office","description":"Network: Studio-5G. Password in 1Password.","updated":"2026-09-02T12:00:00Z","hits":0,"badge":"never recalled"}],
         "summary":{"text":"You work in design, live in Milan, and keep mornings for deep work. Bills and home admin are where things slip.","note":"Rewritten nightly from what Otto keeps."},
         "generatedAt":"2026-11-04T03:00:00Z",
         "graph":{"c":[0,1,0,2,1],"clusters":[{"id":0,"size":2,"label":"Routines","terms":["morning","coffee"]},{"id":1,"size":2,"label":"Work","terms":["design","marta"]},{"id":2,"size":1,"label":"Home","terms":["boiler"]}]}}
        """,
        "people": """
        {"cards":[
          {"name":"Marta Rossi","relationship":"Design lead","city":"Milan","timezone":"Europe/Rome","org":"Studio","notes":[{"at":"2026-11-03","text":"Wants the slides by Wednesday."}],"inbound":24,"outbound":19,"lastContact":"2026-11-03T16:00:00Z","mentions":[1,3,2,4,6,3,5]},
          {"name":"Luca","relationship":"Landlord","city":"Milan","timezone":"Europe/Rome","notes":[{"at":"2026-11-02","text":"Boiler service, Tuesday morning."}],"inbound":6,"outbound":5,"lastContact":"2026-11-02T18:20:00Z","mentions":[0,1,0,0,2,1,1]},
          {"name":"Sam Lee","relationship":"Friend","city":"New York","timezone":"America/New_York","notes":[],"inbound":11,"outbound":8,"lastContact":"2026-10-29T21:00:00Z","mentions":[2,0,1,1,0,0,1]},
          {"name":"Dr. Bianchi","relationship":"Dentist","city":"Milan","timezone":"Europe/Rome","notes":[],"inbound":1,"outbound":2,"lastContact":"2026-10-21T10:00:00Z","mentions":[0,0,0,1,0,0,0]}]}
        """,
        "money": """
        {"records":[
          {"id":"r1","merchant":"Esselunga","amount":46.80,"currency":"EUR","date":"2026-11-04","category":"Groceries","method":"Apple Pay"},
          {"id":"r2","merchant":"Enel Energia","amount":112.00,"currency":"EUR","date":"2026-11-03","category":"Bills","method":"Bank transfer"},
          {"id":"r3","merchant":"Trenitalia","amount":29.90,"currency":"EUR","date":"2026-11-02","category":"Travel","method":"Apple Pay"},
          {"id":"r4","merchant":"Bar Luce","amount":4.50,"currency":"EUR","date":"2026-11-02","category":"Eating out","method":"Apple Pay","note":"flat white + brioche"},
          {"id":"r5","merchant":"Delta","amount":412.00,"currency":"USD","date":"2026-10-30","category":"Travel","method":"Card"}],
         "byCurrency":[{"currency":"EUR","total":193.20,"count":4},{"currency":"USD","total":412.00,"count":1}],
         "byMonth":[{"month":"2026-11","totals":[{"currency":"EUR","total":193.20,"count":4}]},{"month":"2026-10","totals":[{"currency":"EUR","total":1284.10,"count":38},{"currency":"USD","total":412.00,"count":1}]}],
         "byCategory":[{"category":"Bills","total":112.00,"count":1},{"category":"Groceries","total":46.80,"count":1},{"category":"Travel","total":29.90,"count":1},{"category":"Eating out","total":4.50,"count":1}]}
        """,
        "trips": """
        {"trips":[{"id":"t1","start":"2026-11-06","end":"2026-11-10","segments":[
            {"kind":"flight","flight":"TA 482","carrier":"TAP","from":"SFO","to":"JFK","depart":{"local":"2026-11-06T09:25","zone":"America/Los_Angeles"},"arrive":{"local":"2026-11-06T17:55","zone":"America/New_York"}},
            {"kind":"hotel","name":"The Jane","city":"New York","checkIn":"2026-11-06","checkOut":"2026-11-10"},
            {"kind":"flight","flight":"DL 410","carrier":"Delta","from":"JFK","to":"SFO","depart":{"local":"2026-11-10T08:00","zone":"America/New_York"},"arrive":{"local":"2026-11-10T11:30","zone":"America/Los_Angeles"}}]}],
         "current":null,"problems":{}}
        """,
        "packages": """
        {"packages":[
          {"id":"k1","carrier":"ups","carrierName":"UPS","tracking":"1Z999AA10123456784","merchant":"Apple","item":"MagSafe charger","status":"out_for_delivery","eta":"2026-11-04","updatedAt":"2026-11-04T07:30:00Z","events":[{"at":"2026-11-04T07:30:00Z","status":"out_for_delivery","text":"Out for delivery"}]},
          {"id":"k2","carrier":"dhl","carrierName":"DHL","merchant":"Zalando","item":"Running shoes","status":"in_transit","eta":"2026-11-07","updatedAt":"2026-11-03T19:00:00Z","events":[]}]}
        """,
        "status": """
        {"rows":[
          {"id":"mcp","label":"MCP server","verdict":"up","at":1793865600,"detail":"Answering, 42 ms"},
          {"id":"triggers","label":"Trigger engine","verdict":"up","at":1793865600,"detail":"5 armed, next in 2 h"},
          {"id":"email","label":"Email scan","verdict":"up","at":1793865600,"detail":"Last scan 4 min ago"},
          {"id":"voice","label":"Voice daemon","verdict":"degraded","at":1793865600,"detail":"Restarted twice today"},
          {"id":"relay","label":"Phone relay","verdict":"off","detail":"Not set up"}],
         "repairs":["03:02 voice daemon restarted (exit 137)"]}
        """,
        "jobs": """
        {"jobs":[
          {"id":"j1","task":"Compare three flat insurance quotes","state":"running","createdAt":"2026-11-11T08:40:00Z","costUsd":0.42},
          {"id":"j2","task":"Summarise the building assembly minutes","state":"queued","createdAt":"2026-11-11T08:10:00Z","notBefore":"2026-11-12T01:00:00Z"},
          {"id":"j3","task":"Find a quieter route to the office","state":"done","createdAt":"2026-11-10T18:00:00Z","costUsd":0.18,"result":"**Take Elm Street.** Two minutes longer, no main road.\\n\\n- 14 min walk\\n- one crossing"},
          {"id":"j4","task":"Check the train strike dates","state":"failed","createdAt":"2026-11-09T19:00:00Z","costUsd":0.05,"error":"The timetable site didn't answer."}]}
        """,
        "capabilities": """
        {"entries":[
          {"id":"k1","at":"2026-11-10T21:00:00Z","what":"Added a weekly plant-watering reminder","tier":"trigger","origin":"user-message","by":"otto"},
          {"id":"k2","at":"2026-11-08T09:30:00Z","what":"Turned the news digest down to weekly","tier":"trigger","origin":"button-tap","by":"otto","revertedAt":"2026-11-08T10:00:00Z"},
          {"id":"k3","at":"2026-11-05T22:15:00Z","what":"Installed the price-watch recipe for a desk lamp","tier":"recipe","origin":"user-message","by":"otto"}]}
        """,
        "devices": """
        {"devices":[
          {"id":"d1","name":"iPhone","created":"2026-10-01T10:00:00Z","lastUsed":"2026-11-11T08:41:00Z"},
          {"id":"d2","name":"Dashboard","created":"2026-10-12T10:00:00Z","lastUsed":"2026-11-10T19:00:00Z","scope":"write","origin":"https://dash.example.com","ua":"Safari on Mac","expires":"2026-12-12T10:00:00Z"},
          {"id":"d3","name":"Dashboard","created":"2026-09-02T10:00:00Z","lastUsed":"2026-09-20T19:00:00Z","scope":"read","origin":"https://dash.example.com","ua":"Chrome on Windows","expires":"2026-10-02T10:00:00Z"}]}
        """,
        "me": #"{"id":"d1"}"#,
        "memory/item": #"{"body":"Flat white, **oat milk**. No sugar.\n\nOrders it at Bar Luce most mornings."}"#,
        "proactivity": """
        {"stats":[
          {"src":"morning-brief","sent":30,"engaged":21,"silentStreak":0,"lastSent":"2026-11-04T07:57:00Z","lastEngaged":"2026-11-04T08:03:00Z"},
          {"src":"email-scan","sent":18,"engaged":11,"silentStreak":1,"lastSent":"2026-11-04T10:12:00Z"},
          {"src":"bill-reminder","sent":4,"engaged":4,"silentStreak":0,"lastSent":"2026-11-03T09:00:00Z"},
          {"src":"news-digest","sent":9,"engaged":0,"silentStreak":9,"lastSent":"2026-11-04T07:00:00Z"}]}
        """,
    ]
}
