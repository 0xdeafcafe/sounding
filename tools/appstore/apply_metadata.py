import os, re, sys, time, argparse, requests, jwt

APP = "6767263473"
LOCALE = "en-GB"
PLATFORMS = {"IOS": "3. iOS", "TV_OS": "4. Apple TV", "MAC_OS": "5. Mac"}
LIMITS = {"App name": 30, "Subtitle": 30, "Promotional text": 170, "Description": 4000, "Keywords": 100, "What's New": 4000, "Notes": 4000}
BANNED = ["—", "lyric"]


def token():
    kid = os.environ["ASC_KEY_ID"]
    key = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{kid}.p8")).read()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid": kid, "typ": "JWT"})


def call(method, path, body=None):
    r = requests.request(method, "https://api.appstoreconnect.apple.com" + path, headers={"Authorization": "Bearer " + token()}, json=body, timeout=60)
    if r.status_code >= 300:
        raise SystemExit(f"{method} {path} -> {r.status_code} {r.text[:800]}")
    return r.json() if r.text else {}


def parse(path):
    fields, h2, h3 = {}, None, None
    lines = open(path).read().split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("## "):
            h2, h3 = line[3:].strip(), None
        elif line.startswith("### "):
            h3 = re.sub(r"\s*\(max \d+\)$", "", line[4:].strip())
        elif line.startswith("```") and h3 and (h2, h3) not in fields:
            j = i + 1
            while not lines[j].startswith("```"):
                j += 1
            fields[(h2, h3)] = "\n".join(lines[i + 1:j])
            i = j
        i += 1
    return fields


def check(fields):
    problems = []
    for (h2, h3), text in fields.items():
        limit = LIMITS.get(h3)
        if limit and len(text) > limit:
            problems.append(f"{h2} / {h3}: {len(text)} > {limit}")
        for b in BANNED:
            if b in text.lower():
                problems.append(f"{h2} / {h3}: contains {b!r}")
        if h3 in ("App name", "Subtitle", "Keywords") and "soundcloud" in text.lower():
            problems.append(f"{h2} / {h3}: names SoundCloud")
        if h3 == "Description" and "not affiliated" not in text.lower() and "isn't affiliated" not in text.lower():
            problems.append(f"{h2} / {h3}: no independence line")
    return problems


def field(fields, h2prefix, h3):
    for (a, b), v in fields.items():
        if a.startswith(h2prefix) and b == h3:
            return v
    raise SystemExit(f"missing {h2prefix} / {h3}")


AGE = {
    "parentalControls": False, "ageAssurance": False, "unrestrictedWebAccess": False,
    "userGeneratedContent": True, "messagingAndChat": True, "socialMedia": True, "advertising": False,
    "healthOrWellnessTopics": False, "medicalOrTreatmentInformation": "NONE",
    "profanityOrCrudeHumor": "INFREQUENT_OR_MILD", "horrorOrFearThemes": "NONE",
    "alcoholTobaccoOrDrugUseOrReferences": "INFREQUENT_OR_MILD", "matureOrSuggestiveThemes": "INFREQUENT_OR_MILD",
    "sexualContentOrNudity": "NONE", "sexualContentGraphicAndNudity": "NONE",
    "violenceCartoonOrFantasy": "NONE", "violenceRealistic": "NONE", "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    "gunsOrOtherWeapons": "NONE", "gamblingSimulated": "NONE", "gambling": False, "contests": "NONE", "lootBox": False,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metadata", default=os.path.join(os.path.dirname(__file__), "../../Design/appstore/metadata.md"))
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--attach", nargs="*", default=[], metavar="PLATFORM=BUILD_ID")
    args = ap.parse_args()
    fields = parse(args.metadata)
    problems = check(fields)
    for (h2, h3), v in fields.items():
        print(f"{len(v):5}  {h2} / {h3}")
    if problems:
        raise SystemExit("\n".join(problems))
    if not args.apply:
        return

    versions = {v["attributes"]["platform"]: v for v in call("GET", f"/v1/apps/{APP}/appStoreVersions?limit=50")["data"] if v["attributes"]["appStoreState"] == "PREPARE_FOR_SUBMISSION"}
    info = next(i for i in call("GET", f"/v1/apps/{APP}/appInfos")["data"] if i["attributes"]["state"] == "PREPARE_FOR_SUBMISSION")

    loc = next(l for l in call("GET", f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"] if l["attributes"]["locale"] == LOCALE)
    call("PATCH", f"/v1/appInfoLocalizations/{loc['id']}", {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": {
        "name": field(fields, "1.", "App name"), "subtitle": field(fields, "1.", "Subtitle"), "privacyPolicyUrl": field(fields, "1.", "Privacy Policy URL")}}})
    print("appInfoLocalization", LOCALE)

    call("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": "MUSIC"}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": "ENTERTAINMENT"}}}}})
    print("categories MUSIC, ENTERTAINMENT")

    age = call("GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
    call("PATCH", f"/v1/ageRatingDeclarations/{age['id']}", {"data": {"type": "ageRatingDeclarations", "id": age["id"], "attributes": AGE}})
    print("ageRatingDeclaration")

    beta = call("GET", f"/v1/apps/{APP}/betaAppReviewDetail")["data"]["attributes"]
    contact = {k: beta[k] for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail") if beta.get(k)}
    notes = field(fields, "9.", "Notes")

    for platform, section in PLATFORMS.items():
        v = versions.get(platform)
        if not v:
            print("no PREPARE_FOR_SUBMISSION version for", platform)
            continue
        call("PATCH", f"/v1/appStoreVersions/{v['id']}", {"data": {"type": "appStoreVersions", "id": v["id"], "attributes": {"copyright": field(fields, "2.", "Copyright")}}})
        attrs = {
            "description": field(fields, section, "Description"),
            "keywords": field(fields, section, "Keywords"),
            "promotionalText": field(fields, section, "Promotional text"),
            "whatsNew": field(fields, section, "What's New"),
            "supportUrl": field(fields, "2.", "Support URL"),
            "marketingUrl": field(fields, "2.", "Marketing URL"),
        }
        locs = call("GET", f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]
        existing = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
        if existing:
            try:
                call("PATCH", f"/v1/appStoreVersionLocalizations/{existing['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": existing["id"], "attributes": attrs}})
            except SystemExit as e:
                if "whatsNew" not in str(e):
                    raise
                attrs.pop("whatsNew")
                call("PATCH", f"/v1/appStoreVersionLocalizations/{existing['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": existing["id"], "attributes": attrs}})
                print("  whatsNew not editable for a first version")
        else:
            call("POST", "/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations", "attributes": {"locale": LOCALE, **attrs},
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
        print("versionLocalization", platform)

        review_attrs = {"notes": notes, "demoAccountRequired": True, **contact}
        detail = call("GET", f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail").get("data")
        if detail:
            call("PATCH", f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {"type": "appStoreReviewDetails", "id": detail["id"], "attributes": review_attrs}})
        else:
            call("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": review_attrs,
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
        print("reviewDetail", platform, "contact fields:", sorted(contact))

    for pair in args.attach:
        platform, build = pair.split("=")
        v = versions[platform]
        call("PATCH", f"/v1/appStoreVersions/{v['id']}/relationships/build", {"data": {"type": "builds", "id": build}})
        print("build attached", platform, build)


main()
