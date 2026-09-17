#!/usr/bin/env python3
"""Build a reviewable HTML POST form for MusicBrainz's release editor.

The input is a JSON release description.  The output contains no credentials
or JavaScript; opening it in an already logged-in browser and pressing the
button POSTs the documented release-editor seed fields to MusicBrainz.
"""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path
from typing import Any

MUSICBRAINZ_RELEASE_ADD = "https://musicbrainz.org/release/add"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec", type=Path, help="JSON release specification")
    parser.add_argument("output", type=Path, help="HTML file to create")
    return parser.parse_args()


def require_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value.strip()


def toc_lengths_ms(toc_string: str) -> list[int]:
    try:
        values = [int(value) for value in toc_string.split()]
    except ValueError as exc:
        raise ValueError("medium.toc must contain decimal integers") from exc
    if len(values) < 4:
        raise ValueError("medium.toc is too short")
    first, last, leadout, *offsets = values
    track_count = last - first + 1
    if first < 1 or last < first or len(offsets) != track_count:
        raise ValueError("medium.toc track range and offsets disagree")
    if offsets != sorted(offsets) or offsets[0] < 0 or leadout <= offsets[-1]:
        raise ValueError("medium.toc offsets/leadout are not strictly ordered")
    endpoints = [*offsets, leadout]
    return [
        round((endpoints[i + 1] - endpoints[i]) * 1000 / 75) for i in range(track_count)
    ]


def add_credit_fields(fields: list[tuple[str, str]], prefix: str, credits: Any) -> None:
    if not isinstance(credits, list) or not credits:
        raise ValueError(f"{prefix} must be a non-empty list")
    for index, credit in enumerate(credits):
        if not isinstance(credit, dict):
            raise TypeError(f"{prefix}[{index}] must be an object")
        base = f"{prefix}.names.{index}"
        mbid = credit.get("mbid")
        artist_name = credit.get("artist_name")
        credited_name = credit.get("credited_name")
        if mbid:
            fields.append((f"{base}.mbid", require_string(mbid, f"{base}.mbid")))
        elif artist_name:
            fields.append(
                (
                    f"{base}.artist.name",
                    require_string(artist_name, f"{base}.artist_name"),
                )
            )
        else:
            raise ValueError(f"{base} needs mbid or artist_name")
        if credited_name:
            fields.append(
                (f"{base}.name", require_string(credited_name, f"{base}.credited_name"))
            )
        join_phrase = credit.get("join_phrase")
        if join_phrase is not None:
            if not isinstance(join_phrase, str):
                raise ValueError(f"{base}.join_phrase must be a string")
            fields.append((f"{base}.join_phrase", join_phrase))


def build_fields(spec: dict[str, Any]) -> tuple[list[tuple[str, str]], list[int]]:
    fields: list[tuple[str, str]] = [("name", require_string(spec.get("name"), "name"))]
    add_credit_fields(fields, "artist_credit", spec.get("artist_credit"))

    release_types = spec.get("type", [])
    if isinstance(release_types, str):
        release_types = [release_types]
    if not isinstance(release_types, list):
        raise TypeError("type must be a string or list")
    for release_type in release_types:
        fields.append(("type", require_string(release_type, "type")))

    simple_fields = ("status", "language", "script", "packaging", "barcode", "comment")
    for field in simple_fields:
        value = spec.get(field)
        if value is not None:
            fields.append((field, require_string(value, field)))

    event = spec.get("event")
    if event is not None:
        if not isinstance(event, dict):
            raise ValueError("event must be an object")
        for source, target in (
            ("country", "events.0.country"),
            ("year", "events.0.date.year"),
            ("month", "events.0.date.month"),
            ("day", "events.0.date.day"),
        ):
            if event.get(source) not in (None, ""):
                fields.append((target, str(event[source])))

    label = spec.get("label")
    if label is not None:
        if not isinstance(label, dict):
            raise ValueError("label must be an object")
        if label.get("mbid"):
            fields.append(
                ("labels.0.mbid", require_string(label["mbid"], "label.mbid"))
            )
        elif label.get("name"):
            fields.append(
                ("labels.0.name", require_string(label["name"], "label.name"))
            )
        if label.get("catalog_number"):
            fields.append(
                (
                    "labels.0.catalog_number",
                    require_string(label["catalog_number"], "label.catalog_number"),
                )
            )

    medium = spec.get("medium")
    if not isinstance(medium, dict):
        raise TypeError("medium must be an object")
    toc = require_string(medium.get("toc"), "medium.toc")
    lengths = toc_lengths_ms(toc)
    tracks = medium.get("tracks")
    if not isinstance(tracks, list) or len(tracks) != len(lengths):
        raise ValueError(f"medium.tracks must contain exactly {len(lengths)} tracks")
    fields.extend(
        [
            (
                "mediums.0.format",
                require_string(medium.get("format", "CD"), "medium.format"),
            ),
            ("mediums.0.toc", toc),
        ]
    )
    for index, (track, length) in enumerate(zip(tracks, lengths, strict=True)):
        if not isinstance(track, dict):
            raise TypeError(f"medium.tracks[{index}] must be an object")
        base = f"mediums.0.track.{index}"
        fields.extend(
            [
                (f"{base}.number", str(track.get("number", index + 1))),
                (f"{base}.name", require_string(track.get("name"), f"{base}.name")),
                (f"{base}.length", str(length)),
            ]
        )
        add_credit_fields(fields, f"{base}.artist_credit", track.get("artist_credit"))

    annotation = spec.get("annotation")
    if annotation:
        fields.append(("annotation", require_string(annotation, "annotation")))
    edit_note = spec.get("edit_note")
    if edit_note:
        fields.append(("edit_note", require_string(edit_note, "edit_note")))
    return fields, lengths


def format_duration(milliseconds: int) -> str:
    seconds = round(milliseconds / 1000)
    return f"{seconds // 60}:{seconds % 60:02d}"


def render(
    spec: dict[str, Any], fields: list[tuple[str, str]], lengths: list[int]
) -> str:
    title = html.escape(str(spec["name"]))
    tracks = spec["medium"]["tracks"]
    hidden = "\n".join(
        f'      <input type="hidden" name="{html.escape(name, quote=True)}" '
        f'value="{html.escape(value, quote=True)}">'
        for name, value in fields
    )
    rows = "\n".join(
        "        <tr>"
        f"<td>{index + 1}</td>"
        f"<td>{html.escape(str(track['name']))}</td>"
        f"<td>{html.escape(format_duration(lengths[index]))}</td>"
        "</tr>"
        for index, track in enumerate(tracks)
    )
    return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>MusicBrainz seed — {title}</title>
    <style>
      body {{ font: 16px/1.45 system-ui, sans-serif; max-width: 56rem; margin: 3rem auto; padding: 0 1rem; color: #222; }}
      table {{ border-collapse: collapse; width: 100%; margin: 1.5rem 0; }}
      th, td {{ border-bottom: 1px solid #ccc; padding: .45rem; text-align: left; }}
      button {{ background: #ba478f; border: 0; border-radius: .3rem; color: white; cursor: pointer; font-size: 1rem; padding: .8rem 1.1rem; }}
      .note {{ background: #f5f2e9; border-left: .3rem solid #ba478f; padding: .8rem 1rem; }}
      code {{ overflow-wrap: anywhere; }}
    </style>
  </head>
  <body>
    <h1>MusicBrainz release seed: {title}</h1>
    <p class="note">This prepares an edit; it does not submit it. MusicBrainz will show every field for review. Resolve any unmatched artist/label names, check the release, then enter the edit there.</p>
    <p><strong>Disc TOC:</strong> <code>{html.escape(spec["medium"]["toc"])}</code></p>
    <table>
      <thead><tr><th>#</th><th>Track</th><th>Disc duration</th></tr></thead>
      <tbody>
{rows}
      </tbody>
    </table>
    <form action="{MUSICBRAINZ_RELEASE_ADD}" method="post">
{hidden}
      <button type="submit">Open pre-filled MusicBrainz release editor</button>
    </form>
  </body>
</html>
"""


def main() -> None:
    args = parse_args()
    spec = json.loads(args.spec.read_text(encoding="utf-8"))
    if not isinstance(spec, dict):
        raise TypeError("spec root must be an object")
    fields, lengths = build_fields(spec)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(spec, fields, lengths), encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
