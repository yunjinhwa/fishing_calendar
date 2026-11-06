"""Collect exact catalog matches from NIFS's individually KOGL1-marked fish dialogs."""

import argparse
import hashlib
import json
import os
import re
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen

SOURCE = "https://www.nifs.go.kr/contents/actionContentsCons0088.do"
POLICY = "https://www.nifs.go.kr/contents/actionContentsCons0001.do"
CREDIT = "국립수산과학원 · 공공누리 제1유형(출처표시)"
LICENSE_ALT = "공공누리 1유형:출처표시 (상업적 이용 및 변경 가능)"
VOID = set("area base br col embed hr img input link meta param source track wbr".split())


def clean(value):
    return " ".join(value.split())


class Node:
    def __init__(self, tag, attrs=()):
        self.tag, self.attrs, self.children = tag, dict(attrs), []

    def walk(self):
        for child in self.children:
            if isinstance(child, Node):
                yield child
                yield from child.walk()

    def text(self):
        return clean("".join(c.text() if isinstance(c, Node) else c for c in self.children))


class DOM(HTMLParser):
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.root = Node("root")
        self.stack = [self.root]
        self.feed(html)
        self.close()

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs)
        self.stack[-1].children.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def is_dialog(node):
    return (node.attrs.get("role") == "dialog"
            and "modal-content" in node.attrs.get("class", "").split())


def owned_nodes(section):
    """A nested dialog never supplies another dialog's identity or license."""
    for child in section.children:
        if isinstance(child, Node) and not is_dialog(child):
            yield child
            yield from owned_nodes(child)


def official_url(src):
    parsed = urlsplit(urljoin(SOURCE, src))
    if (parsed.scheme, parsed.netloc) != ("https", "www.nifs.go.kr"):
        return None
    return parsed.geturl() if not parsed.query and not parsed.fragment else None


def parse_photos(html):
    """Return photos keyed by the source's exact (국명, 학명) pair, without aliases."""
    document = DOM(html)
    tabs = [n for n in document.root.walk() if n.attrs.get("id") == "tab-1"]
    photos, conflicts = {}, set()
    for section in (n for tab in tabs for n in tab.walk() if is_dialog(n)):
        nodes = list(owned_nodes(section))
        badges = [n for n in nodes if n.tag == "img"
                  and official_url(n.attrs.get("src", "")) ==
                  "https://www.nifs.go.kr/cmmn/images/img_opentype01.png"
                  and clean(n.attrs.get("alt", "")) == LICENSE_ALT]
        identities = []
        for row in (n for n in nodes if n.tag == "tr"):
            cells = [c for c in row.children if isinstance(c, Node) and c.tag in ("th", "td")]
            if len(cells) == 4 and [cells[i].text() for i in (0, 2)] == ["국명", "학명"]:
                identities.append((cells[1].text(), cells[3].text()))
        if not badges or len(identities) != 1 or not all(identities[0]):
            continue
        key = identities[0]
        images = []
        for node in nodes:
            if (node.tag != "img" or "md-img-sel" not in node.attrs.get("class", "").split()
                    or clean(node.attrs.get("alt", "")) != key[0]):
                continue
            url = official_url(node.attrs.get("src", ""))
            if url and re.fullmatch(r"/cmmn/images/MF[A-Za-z0-9_-]+\.(?:png|jpe?g)", urlsplit(url).path):
                images.append(url)
        if len(set(images)) == 1:
            photo = {"imageUrl": images[0], "licenseBadgeAlt": clean(badges[0].attrs["alt"])}
            if key in photos and photos[key] != photo:
                conflicts.add(key)
            photos[key] = photo
    return {key: photo for key, photo in photos.items() if key not in conflicts}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--html", type=Path, default=Path(".dart_tool/nifs_fish_photo_page.html"))
    parser.add_argument("--output", type=Path, default=Path(".dart_tool/fish_nifs_public_photos.json"))
    args = parser.parse_args()
    fetched = not args.html.exists()
    if fetched:
        request = Request(SOURCE, headers={"User-Agent": "FishingBuild-NIFS-photo-collector/1.0"})
        with urlopen(request, timeout=30) as response:
            content = response.read(2 * 1024 * 1024 + 1)
            if len(content) > 2 * 1024 * 1024:
                raise ValueError("Official photo page exceeds the collection limit")
            html = content.decode("utf-8")
        args.html.parent.mkdir(parents=True, exist_ok=True)
        args.html.write_text(html, encoding="utf-8")
    photos = parse_photos(args.html.read_text(encoding="utf-8"))
    if not photos:
        raise ValueError("No verified species sections; existing report is unchanged")
    catalog_bytes = Path("assets/data/fish_catalog.json").read_bytes()
    species = json.loads(catalog_bytes)["species"]
    if len(species) != 800 or len({s["id"] for s in species}) != 800:
        raise ValueError("Expected the complete 800-species catalog")
    current = json.loads(Path("assets/data/fish_enrichment.json").read_text(encoding="utf-8"))
    known = {r["result"]["id"] for r in current["records"] if r["result"].get("imageUrl")}
    checked = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    records = []
    for base in species:
        photo = photos.get((base["name"], base["scientificName"]))
        result = dict(base, feature="", imageUrl=None, photoAttribution=None, photoSourceUrl=None,
                      photoLicenseUrl=None, descriptionSourceUrl=None, descriptionAttribution=None,
                      detailNeedsRetry=False)
        if photo:
            result.update(imageUrl=photo["imageUrl"], photoAttribution=CREDIT,
                          photoSourceUrl=SOURCE, photoLicenseUrl=POLICY)
        record = {key: base[key] for key in ("id", "name", "scientificName")}
        record.update(checkedAt=checked, outcome="success" if photo else "noData",
                      reason=None if photo else "noExactLicensedNifsPhoto", photo=bool(photo), result=result)
        if photo:
            record["identityEvidence"] = {"exactKoreanName": True, "exactScientificName": True,
                                          "sectionLicense": "KOGL1", **photo}
        records.append(record)
    successes = [r for r in records if r["photo"]]
    summary = {"success": len(successes), "noData": len(records) - len(successes),
               "newPhotos": sum(r["id"] not in known for r in successes)}
    report = {"version": 1, "catalogSha256": hashlib.sha256(catalog_bytes).hexdigest(),
              "catalogRecordCount": len(species), "sourceEnabledMode": "nifs-dialog-photos-exact-identity-v1",
              "sourceUrl": SOURCE, "checkedAt": checked, "requestCount": int(fetched),
              "records": records, "summary": summary}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, args.output)
    print(json.dumps({"sourcePhotos": len(photos), **summary}))


if __name__ == "__main__":
    main()
