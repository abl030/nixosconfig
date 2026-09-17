#!/usr/bin/env python3
"""Build a review page of pre-filled MusicBrainz artist-create links."""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path
from typing import Any

MUSICBRAINZ_ARTIST_CREATE = "https://musicbrainz.org/artist/create"


def require_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value.strip()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec", type=Path, help="JSON artist specification")
    parser.add_argument("output", type=Path, help="HTML file to create")
    return parser.parse_args()


def artist_fields(artist: dict[str, Any], index: int) -> list[tuple[str, str]]:
    prefix = f"artists[{index}]"
    fields = [
        ("edit-artist.name", require_string(artist.get("name"), f"{prefix}.name")),
        (
            "edit-artist.sort_name",
            require_string(artist.get("sort_name"), f"{prefix}.sort_name"),
        ),
        (
            "edit-artist.comment",
            require_string(artist.get("disambiguation"), f"{prefix}.disambiguation"),
        ),
    ]
    type_id = artist.get("type_id", 1)
    if not isinstance(type_id, int) or type_id < 1:
        raise ValueError(f"{prefix}.type_id must be a positive integer")
    fields.append(("edit-artist.type_id", str(type_id)))
    if area := artist.get("area"):
        fields.append(("edit-artist.area.name", require_string(area, f"{prefix}.area")))
    if edit_note := artist.get("edit_note"):
        fields.append(
            ("edit-artist.edit_note", require_string(edit_note, f"{prefix}.edit_note"))
        )
    external_links = artist.get("external_links", [])
    if not isinstance(external_links, list):
        raise TypeError(f"{prefix}.external_links must be a list")
    for link_index, link in enumerate(external_links):
        link_prefix = f"{prefix}.external_links[{link_index}]"
        if not isinstance(link, dict):
            raise TypeError(f"{link_prefix} must be an object")
        link_type_id = link.get("link_type_id")
        if not isinstance(link_type_id, int) or link_type_id < 1:
            raise ValueError(f"{link_prefix}.link_type_id must be a positive integer")
        base = f"edit-artist.url.{link_index}"
        fields.extend(
            [
                (f"{base}.text", require_string(link.get("url"), f"{link_prefix}.url")),
                (f"{base}.link_type_id", str(link_type_id)),
            ]
        )
    return fields


def render(spec: dict[str, Any]) -> str:
    artists = spec.get("artists")
    if not isinstance(artists, list) or not artists:
        raise ValueError("artists must be a non-empty list")

    cards = []
    for index, artist in enumerate(artists):
        if not isinstance(artist, dict):
            raise TypeError(f"artists[{index}] must be an object")
        fields = artist_fields(artist, index)
        name = html.escape(str(artist["name"]))
        hidden = "\n".join(
            f'        <input type="hidden" name="{html.escape(key, quote=True)}" '
            f'value="{html.escape(value, quote=True)}">'
            for key, value in fields
        )
        evidence = artist.get("evidence", [])
        if not isinstance(evidence, list):
            raise TypeError(f"artists[{index}].evidence must be a list")
        links = "".join(
            f'<li><a href="{html.escape(require_string(url, f"artists[{index}].evidence"), quote=True)}">'
            f"{html.escape(url)}</a></li>"
            for url in evidence
        )
        seeded_links = "".join(
            f"<li>{html.escape(str(link['url']))} (relationship type {link['link_type_id']})</li>"
            for link in artist.get("external_links", [])
        )
        cards.append(
            f"""    <section>
      <h2>{name}</h2>
      <dl>
        <dt>Sort name</dt><dd>{html.escape(str(artist["sort_name"]))}</dd>
        <dt>Disambiguation</dt><dd>{html.escape(str(artist["disambiguation"]))}</dd>
        <dt>Area</dt><dd>{html.escape(str(artist.get("area", "unknown")))}</dd>
      </dl>
      <p>Evidence:</p><ul>{links}</ul>
      <p>Seeded MusicBrainz external links:</p><ul>{seeded_links or "<li>None</li>"}</ul>
      <form action="{MUSICBRAINZ_ARTIST_CREATE}" method="get" target="_blank">
{hidden}
        <button type="submit">Create {name} in MusicBrainz</button>
      </form>
    </section>"""
        )

    return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>MusicBrainz artist seeds</title>
    <style>
      body {{ font: 16px/1.45 system-ui, sans-serif; max-width: 60rem; margin: 2rem auto; padding: 0 1rem; color: #222; }}
      section {{ border: 1px solid #ccc; border-radius: .4rem; margin: 1rem 0; padding: 1rem 1.25rem; }}
      dl {{ display: grid; grid-template-columns: 10rem 1fr; gap: .25rem 1rem; }}
      dt {{ font-weight: bold; }} dd {{ margin: 0; }}
      button {{ background: #ba478f; border: 0; border-radius: .3rem; color: white; cursor: pointer; padding: .7rem 1rem; }}
      .note {{ background: #f5f2e9; border-left: .3rem solid #ba478f; padding: .8rem 1rem; }}
      a {{ overflow-wrap: anywhere; }}
    </style>
  </head>
  <body>
    <h1>MusicBrainz artist creation</h1>
    <p class="note">Each button opens one pre-filled artist editor. Review it and enter the edit, then close that tab. In the release editor, use the magnifying glass to select the new artist so the field turns green. These forms do not submit edits automatically.</p>
{chr(10).join(cards)}
  </body>
</html>
"""


def main() -> None:
    args = parse_args()
    spec = json.loads(args.spec.read_text(encoding="utf-8"))
    if not isinstance(spec, dict):
        raise TypeError("spec root must be an object")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(spec), encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
