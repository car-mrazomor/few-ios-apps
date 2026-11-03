# iFuck AI

Run Hugging Face models privately on your iPhone. So rude, but who cares.

- Search Hugging Face for any GGUF model and download it in the background
- See if a model will run before downloading: architecture, memory and speed estimates read straight from the file header
- Chat with streaming replies, thinking blocks and tokens/sec stats
- Vision models: ask about photos from your library or the camera
- Attach PDFs and text files
- Import your own `.gguf` files
- Dark, Light and Odysseus themes

Powered by [llama.cpp](https://github.com/ggml-org/llama.cpp) with Metal. Nothing leaves the device.

## Build

```sh
brew install xcodegen
scripts/fetch-deps.sh
xcodegen generate
open iFuckAI.xcodeproj
```

`scripts/build-ipa.sh` builds an unsigned `.ipa` for sideloading. `python3 scripts/set-logo.py logo.png` sets the logo and app icon.
