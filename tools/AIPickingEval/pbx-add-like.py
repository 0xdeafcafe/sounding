import hashlib
import re
import sys

path = "SoundingTV.xcodeproj/project.pbxproj"
like = sys.argv[1]
news = sys.argv[2:3]
text = open(path).read()
lines = text.split("\n")


def new_id(seed):
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


ref_line = next(i for i, l in enumerate(lines) if f"/* {like} */ = {{isa = PBXFileReference;" in l)
ref_id = lines[ref_line].strip().split(" ")[0]
group_line = next(i for i, l in enumerate(lines) if l.strip() == f"{ref_id} /* {like} */,")
build_ids = re.findall(rf"(\w{{24}}) /\* {re.escape(like)} in Sources \*/ = {{isa = PBXBuildFile; fileRef = {ref_id}", text)

for name in reversed(news):
    if f"path = {name};" in text:
        print("exists", name)
        continue
    fid = new_id("ref" + name)
    inserts = []
    inserts.append((ref_line, lines[ref_line].replace(ref_id, fid).replace(like, name)))
    inserts.append((group_line, lines[group_line].replace(ref_id, fid).replace(like, name)))
    for bid in build_ids:
        nbid = new_id("build" + name + bid)
        bl = next(i for i, l in enumerate(lines) if l.strip().startswith(f"{bid} /* {like} in Sources */ = {{isa = PBXBuildFile;"))
        inserts.append((bl, lines[bl].replace(bid, nbid).replace(ref_id, fid).replace(like, name)))
        pl = next(i for i, l in enumerate(lines) if l.strip() == f"{bid} /* {like} in Sources */,")
        inserts.append((pl, lines[pl].replace(bid, nbid).replace(like, name)))
    for index, line in sorted(inserts, key=lambda x: -x[0]):
        lines.insert(index + 1, line)
    text = "\n".join(lines)
    print("added", name, len(build_ids), "targets")

open(path, "w").write("\n".join(lines))
