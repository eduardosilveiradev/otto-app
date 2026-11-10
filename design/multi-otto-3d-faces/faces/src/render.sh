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

render() {
  agent-browser --session faces open "file://$PWD/render.html?$1" >/dev/null
  agent-browser --session faces eval "c.toDataURL('image/png')" | tr -d '"' | sed 's/^data:image\/png;base64,//' | base64 -d > "../$1.png"
}

for face in ${@:-$(all)}; do
  if [[ $face == *-blink ]]; then             # a blink is a strip of three frames, played by object-position in style.css
    base=${face%-blink}
    for n in 1 2 3; do render "$base-b$n"; done
    magick "../$base-b1.png" "../$base-b2.png" "../$base-b3.png" +append "../$face.png"
    rm "../$base-b1.png" "../$base-b2.png" "../$base-b3.png"
  else
    render "$face"
  fi
done
