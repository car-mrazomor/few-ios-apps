# few-ios-apps

A few simple iOS apps I made. Each folder is its own Xcode project (generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`).

| App | What it does |
|---|---|
| [PocketCode](PocketCode) | Python on the iPhone: terminal, Vim-style editor and notebooks, with pip and git |
| [PocketShell](PocketShell) | SSH client with key support, plus the PocketCode tools built in |
| [MinnetCam](MinnetCam) | Live camera recognition, fully on device, with [minnet](https://github.com/car-mrazomor/minnet) (a CNN written from scratch in C) |
| [iFuckAI](iFuckAI) | Run Hugging Face GGUF models privately on the iPhone with llama.cpp |

## Build

```sh
brew install xcodegen
cd <App>
scripts/fetch-deps.sh   # PocketCode, PocketShell, iFuckAI: downloads Python / llama.cpp into Vendor/
xcodegen generate
open <App>.xcodeproj
```
