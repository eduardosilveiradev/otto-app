#!/bin/bash
# Renders the faces to ../*.png in a real browser through agent-browser (WebGL2 needs a GPU).
# Pass face names to render only those.
set -euo pipefail
cd "$(dirname "$0")"

all() {
  for who in otto inbox code school home fares stays; do
    echo "$who-rest" "$who-rest-blink" "$who-working" "$who-working-blink" "$who-needs" "$who-asleep" "$who-gpt" "$who-failed" "$who-failed-blink"
  done
}

for face in ${@:-$(all)}; do
  agent-browser --session faces open "file://$PWD/render.html?$face" >/dev/null
  agent-browser --session faces eval "c.toDataURL('image/png')" | tr -d '"' | sed 's/^data:image\/png;base64,//' | base64 -d > "../$face.png"
done
