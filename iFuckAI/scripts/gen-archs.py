import re
import sys
import urllib.request

tag = sys.argv[1] if len(sys.argv) > 1 else open("Vendor/.tag").read().strip()
url = f"https://raw.githubusercontent.com/ggml-org/llama.cpp/{tag}/src/llama-arch.cpp"
src = urllib.request.urlopen(url).read().decode()
block = re.search(r"LLM_ARCH_NAMES\s*=\s*\{(.*?)\};", src, re.S).group(1)
names = [n for n in re.findall(r'\{\s*LLM_ARCH_\w+\s*,\s*"([^"]+)"', block) if n != "(unknown)"]

lines = ",\n".join(f'        "{n}"' for n in names)
out = f"""enum Architectures {{
    static let llamaBuild = "{tag}"

    static let supported: Set<String> = [
{lines}
    ]
}}
"""
open("iFuckAI/Hub/Architectures.swift", "w").write(out)
print(f"{len(names)} architectures from {tag}")
