#!/usr/bin/env python3
"""
Phase 6 Plan 06-04 (REL-06) — prepend a signed Sparkle <item> to appcast.xml.

Called by .github/workflows/release.yml after `sign_update` produces the
EdDSA signature line. Python 3 stdlib only — NO `pip install` (Pitfall:
the threat model treats every external install as a supply-chain risk;
stdlib-only keeps the appcast helper auditable).

Usage:
    python3 scripts/append_appcast_item.py \\
        --version 1.0.0 \\
        --build-number 42 \\
        --dmg-url https://github.com/OWNER/REPO/releases/download/v1.0.0/AgentsUsageBar-1.0.0.dmg \\
        --sig-line 'sparkle:edSignature="ABC..." length="123456"' \\
        appcast.xml

Behavior:
  1. If appcast.xml does not exist, seed it from scripts/appcast.template.xml.
  2. Parse --sig-line for edSignature + length attributes.
  3. PREPEND a new <item> at the top of <channel> so Sparkle sees the
     newest version first (Pattern 5 — newest-first ordering).
  4. Generate <pubDate> via email.utils.formatdate(usegmt=True), which
     emits an RFC-822 / RFC-1123 date string that is locale-INDEPENDENT.
     (Pitfall 9 — Calendar.current on a Thai-locale machine would produce
     Buddhist Era year 2569; email.utils.formatdate uses UTC + English
     day/month names regardless of locale.)
  5. <sparkle:version> = build-number (CFBundleVersion integer that
     Sparkle compares; Pitfall 1).
  6. <sparkle:shortVersionString> = version (human-readable).
  7. <sparkle:minimumSystemVersion>14.0 (project deployment target).

Idempotency: the script PREPENDS one item per invocation. Running it
twice with the same arguments produces two identical <item> elements;
the CI workflow invokes it exactly once per release, so this is correct.
"""

from __future__ import annotations

import argparse
import email.utils
import os
import re
import shutil
import sys
import time
from pathlib import Path
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# Register the prefix so ElementTree serializes `sparkle:` instead of an
# auto-generated `ns0:` prefix. This is the documented way to preserve
# the canonical Sparkle namespace prefix on output.
ET.register_namespace("sparkle", SPARKLE_NS)


# Resolve the template next to this script (works regardless of cwd).
SCRIPT_DIR = Path(__file__).resolve().parent
TEMPLATE_PATH = SCRIPT_DIR / "appcast.template.xml"


def parse_sig_line(sig_line: str) -> tuple[str, str]:
    """
    Extract edSignature + length attribute values from a sign_update output line.

    sign_update prints a single line of the form:
        sparkle:edSignature="BASE64_SIG" length="123456"

    Returns (signature, length) as strings (length kept as string — it
    rides into XML as an attribute string anyway).
    """
    sig_match = re.search(r'sparkle:edSignature="([^"]+)"', sig_line)
    len_match = re.search(r'length="([^"]+)"', sig_line)
    if not sig_match or not len_match:
        raise ValueError(
            f"--sig-line did not match expected sign_update output shape; got: {sig_line!r}"
        )
    return sig_match.group(1), len_match.group(1)


def ensure_appcast_exists(target: Path) -> None:
    """Seed target from scripts/appcast.template.xml if it does not exist."""
    if target.exists():
        return
    if not TEMPLATE_PATH.exists():
        raise FileNotFoundError(
            f"appcast template missing at {TEMPLATE_PATH}; cannot seed {target}"
        )
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(TEMPLATE_PATH, target)


def rfc822_pubdate_now() -> str:
    """
    Return the current UTC time as an RFC-822 date string.

    email.utils.formatdate(usegmt=True) is locale-independent — it always
    emits English day/month names and uses UTC. Contrast with strftime
    + locale, which on a Thai-locale system would emit Buddhist Era years
    or Thai day names (Pitfall 9).
    """
    return email.utils.formatdate(time.time(), usegmt=True)


def make_item(
    *,
    version: str,
    build_number: str,
    dmg_url: str,
    edsig: str,
    length: str,
) -> ET.Element:
    """Build a new <item> Element with all required Sparkle fields."""
    item = ET.Element("item")

    title = ET.SubElement(item, "title")
    title.text = f"Version {version}"

    pub_date = ET.SubElement(item, "pubDate")
    pub_date.text = rfc822_pubdate_now()

    # Use ET.QName so the serialized output is `sparkle:version`, not
    # `{http://...}version`.
    sparkle_version = ET.SubElement(item, ET.QName(SPARKLE_NS, "version"))
    sparkle_version.text = str(build_number)

    sparkle_short = ET.SubElement(item, ET.QName(SPARKLE_NS, "shortVersionString"))
    sparkle_short.text = str(version)

    sparkle_min = ET.SubElement(item, ET.QName(SPARKLE_NS, "minimumSystemVersion"))
    sparkle_min.text = "14.0"

    # Release-notes link points to the GitHub Release page derived from
    # the DMG URL's parent (.../releases/download/<tag>/<file> →
    # .../releases/tag/<tag>).
    notes_link = ET.SubElement(item, ET.QName(SPARKLE_NS, "releaseNotesLink"))
    notes_link.text = derive_release_notes_link(dmg_url)

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", dmg_url)
    # `sparkle:` prefix is preserved because register_namespace ran at module load.
    enclosure.set(f"{{{SPARKLE_NS}}}edSignature", edsig)
    enclosure.set("length", length)
    enclosure.set("type", "application/octet-stream")

    return item


def derive_release_notes_link(dmg_url: str) -> str:
    """
    Derive the GitHub Release page URL from the DMG download URL.

    Input:  https://github.com/OWNER/REPO/releases/download/v1.0.0/AgentsUsageBar-1.0.0.dmg
    Output: https://github.com/OWNER/REPO/releases/tag/v1.0.0
    """
    m = re.match(
        r"^(https?://[^/]+/[^/]+/[^/]+/releases)/download/([^/]+)/[^/]+$",
        dmg_url,
    )
    if m:
        return f"{m.group(1)}/tag/{m.group(2)}"
    # Fall back to the DMG URL itself so we never emit an empty link.
    return dmg_url


def prepend_item(appcast_path: Path, item: ET.Element) -> None:
    """Parse appcast.xml, prepend `item` to <channel>, and write back."""
    tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        raise ValueError(f"{appcast_path} has no <channel> element")
    # Find the index after the last metadata element (title/link/description/language)
    # so the new item lands at the TOP of the items list, NOT before the metadata.
    metadata_tags = {"title", "link", "description", "language"}
    insert_at = 0
    for i, child in enumerate(list(channel)):
        if child.tag in metadata_tags:
            insert_at = i + 1
        elif child.tag == "item":
            # First existing item — newest-first means we insert BEFORE it.
            insert_at = i
            break
    channel.insert(insert_at, item)
    # Preserve the XML declaration; ElementTree.write(... xml_declaration=True)
    # emits `<?xml version='1.0' encoding='utf-8'?>` at the top.
    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Prepend a signed <item> to a Sparkle appcast.xml."
    )
    parser.add_argument("--version", required=True, help="MARKETING_VERSION (e.g. 1.0.0)")
    parser.add_argument(
        "--build-number", required=True, help="CFBundleVersion integer (Sparkle compares this)"
    )
    parser.add_argument("--dmg-url", required=True, help="HTTPS URL to the signed DMG")
    parser.add_argument(
        "--sig-line",
        required=True,
        help='Raw sign_update output, e.g. \'sparkle:edSignature="..." length="..."\'',
    )
    parser.add_argument("appcast", help="Path to appcast.xml (seeded from template if missing)")
    args = parser.parse_args(argv)

    appcast_path = Path(args.appcast)
    ensure_appcast_exists(appcast_path)

    edsig, length = parse_sig_line(args.sig_line)

    item = make_item(
        version=args.version,
        build_number=args.build_number,
        dmg_url=args.dmg_url,
        edsig=edsig,
        length=length,
    )

    prepend_item(appcast_path, item)
    print(
        f"Prepended item: version={args.version} build={args.build_number} "
        f"length={length} → {appcast_path}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
